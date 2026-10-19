defmodule Nobi.Data.Codec do
  @moduledoc """
  Field values to SQLite cells and back.

  Writing is by the field's type: `Int` and `Float` as themselves, `Bool` as `0`/`1`,
  `String` as itself, `Uuid` as its canonical text, `Option` of one of
  those as the inner value or `NULL`; anything else as canonical JSON text
  (`Nobi.Lang.Rt.Json`), an `Option` of it `None` as `NULL`. A JSON cell
  is written only when it reads back as the very value written, so a value
  JSON cannot hold faithfully (a function, `Some(None)` in an
  `Option<Option<…>>`) is refused, never stored as another. A deftype's value (`Result` too) is JSON, read
  back by the image's deftype table.

  Reading is type-directed by the reader's signature (`decode_row/4`): a
  column the row lacks takes the field's default (an `Option` without one,
  `None`); `NULL` reads as `None` for an `Option` and as the default
  otherwise. A cell that is not a value of its field's type is an error,
  never a value. The error names the field and its type, never the stored
  value (that is logged): a program's user reads it.

  ## Tables

  `tables` is what typing a value needs: `%{models: models, types:
  types}`, the image's `__nobi__(:models)` and `__nobi__(:types)`
  (`tables/1` makes it from either, or from a models table alone).
  """

  require Logger

  alias Nobi.Lang.Format
  alias Nobi.Lang.Rt.Json

  @scalars ["Int", "Float", "Bool", "String", "Uuid"]
  @none {:var, "Option", "None", []}
  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @type tables :: %{models: map(), types: map()}

  @doc "`tables` from `%{models:, types:}` or a models table alone (no deftypes)."
  @spec tables(map()) :: tables()
  def tables(%{models: models} = t) when is_map(models),
    do: %{models: models, types: Map.get(t, :types, %{})}

  def tables(models) when is_map(models), do: %{models: models, types: %{}}

  @doc "Whether a field of `type` is a plain column (not JSON)."
  @spec scalar?(term()) :: boolean()
  def scalar?({:named, t}), do: t in @scalars
  def scalar?(_), do: false

  @doc "Whether `s` is a canonical (lowercase) Uuid text."
  @spec uuid_text?(term()) :: boolean()
  def uuid_text?(s), do: is_binary(s) and Regex.match?(@uuid, s)

  # ---------- writing ----------

  @doc """
  The cells of `row` (`{:rec, model, fields}`) for `columns`, a layout's
  `[{field, type, default, column}]`: `{:ok, [{column, cell}]}` or
  `{:error, message}`.
  """
  @spec encode_row(String.t(), list(), term(), map()) ::
          {:ok, [{String.t(), term()}]} | {:error, String.t()}
  def encode_row(model, columns, {:rec, model, fields}, tables) when is_map(fields) do
    models = tables(tables)

    Enum.reduce_while(columns, {:ok, []}, fn {field, type, _default, col}, {:ok, acc} ->
      with {:ok, v} <- fetch_field(fields, field),
           {:ok, cell} <- encode(type, v, models) do
        {:cont, {:ok, [{col, cell} | acc]}}
      else
        {:error, why} -> {:halt, {:error, "#{model}.#{field}: #{why}"}}
      end
    end)
    |> case do
      {:ok, cells} -> {:ok, Enum.reverse(cells)}
      error -> error
    end
  end

  def encode_row(model, _columns, row, _tables),
    do: {:error, "a row of #{model} must be a #{model} record, got #{inspect_kind(row)}"}

  defp fetch_field(fields, field) do
    case Map.fetch(fields, field) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, "the row has no value for it"}
    end
  end

  @doc """
  The cell holding `v`, a value of `type`: `{:ok, cell}` or `{:error,
  why}`. `models` is a `tables/1` argument.
  """
  @spec encode(term(), term(), map()) :: {:ok, term()} | {:error, String.t()}
  def encode(type, v, models) when not is_map_key(models, :models),
    do: encode(type, v, tables(models))

  def encode({:named, "Int"}, n, _models) when is_integer(n) and n >= @i64_min and n <= @i64_max,
    do: {:ok, n}

  def encode({:named, "Float"}, f, _models) when is_float(f), do: {:ok, f}
  def encode({:named, "Bool"}, true, _models), do: {:ok, 1}
  def encode({:named, "Bool"}, false, _models), do: {:ok, 0}

  def encode({:named, "String"}, s, _models) when is_binary(s) do
    if String.valid?(s), do: {:ok, s}, else: {:error, "not a String (invalid UTF-8)"}
  end

  def encode({:named, "Uuid"}, {:uuid, s}, _models) do
    if uuid_text?(s), do: {:ok, s}, else: {:error, "not a canonical Uuid"}
  end

  def encode({:named, t}, v, _models) when t in @scalars,
    do: {:error, "expected #{t}, got #{inspect_kind(v)}"}

  def encode({:applied, "Option", [_]}, @none, _models), do: {:ok, nil}

  def encode({:applied, "Option", [inner]} = type, {:var, "Option", "Some", [x]} = v, models) do
    if scalar?(inner), do: encode(inner, x, models), else: json(type, v, models)
  end

  def encode({:applied, "Option", [_]}, v, _models),
    do: {:error, "expected an Option, got #{inspect_kind(v)}"}

  def encode(type, v, models), do: json(type, v, models)

  defp json(type, v, %{models: models, types: types}) do
    case Json.stringify(v, type, models) do
      {:var, "Result", "Ok", [text]} ->
        if Json.decode_stored(text, type, models, types) == {:ok, v},
          do: {:ok, text},
          else:
            {:error, "the value does not read back as itself from JSON, so it cannot be stored"}

      {:var, "Result", "Err", [why]} ->
        {:error, why}
    end
  catch
    {:nobi_error, why} -> {:error, why}
  end

  # ---------- reading ----------

  @doc """
  The record of `model` a table row holds. `cells` maps column names to
  cells; `columns` is the reader's layout. `{:ok, record}` or `{:error,
  message}`.
  """
  @spec decode_row(String.t(), list(), map(), map()) :: {:ok, term()} | {:error, String.t()}
  def decode_row(model, columns, cells, tables) do
    tables = tables(tables)

    with {:ok, id} <- decode_id(model, Map.get(cells, "id")) do
      Enum.reduce_while(columns, {:ok, %{"id" => id}}, fn {field, type, default, col},
                                                          {:ok, acc} ->
        case decode_cell(type, default, Map.fetch(cells, col), tables) do
          {:ok, v} ->
            {:cont, {:ok, Map.put(acc, field, v)}}

          {:error, why} ->
            {:halt, {:error, "#{model}.#{field}: #{why}"}}

          {:error, why, detail} ->
            Logger.warning("Nobi.Data.Codec: #{model}.#{field}: #{detail}")
            {:halt, {:error, "#{model}.#{field}: #{why}"}}
        end
      end)
      |> case do
        {:ok, fields} -> {:ok, {:rec, model, fields}}
        error -> error
      end
    end
  end

  defp decode_id(model, cell) do
    if uuid_text?(cell) do
      {:ok, {:uuid, cell}}
    else
      Logger.warning("Nobi.Data.Codec: #{model}.id: #{inspect(cell, limit: 5)} is not a Uuid")
      {:error, "#{model}.id: the stored id is not a Uuid"}
    end
  end

  # The column is absent: written before the field existed.
  defp decode_cell(type, default, :error, _models), do: absent(type, default)

  defp decode_cell({:applied, "Option", [_]}, _default, {:ok, nil}, _models), do: {:ok, @none}
  defp decode_cell(type, default, {:ok, nil}, _models), do: absent(type, default)
  defp decode_cell(type, _default, {:ok, cell}, models), do: decode(type, cell, models)

  defp absent(_type, default) when default != :none, do: {:ok, default}
  defp absent({:applied, "Option", [_]}, :none), do: {:ok, @none}
  defp absent(_type, :none), do: {:error, "the stored value is NULL and the field has no default"}

  defp decode({:named, "Int"}, n, _models) when is_integer(n), do: {:ok, n}
  defp decode({:named, "Float"}, f, _models) when is_float(f), do: {:ok, Nobi.Lang.Rt.fnorm(f)}
  # SQLite may hand a whole REAL back as an integer.
  defp decode({:named, "Float"}, n, _models) when is_integer(n), do: {:ok, n * 1.0}
  defp decode({:named, "Bool"}, 1, _models), do: {:ok, true}
  defp decode({:named, "Bool"}, 0, _models), do: {:ok, false}

  defp decode({:named, "String"}, s, _models) when is_binary(s) do
    if String.valid?(s), do: {:ok, s}, else: bad("String", s)
  end

  defp decode({:named, "Uuid"} = t, s, _models) do
    if uuid_text?(s), do: {:ok, {:uuid, s}}, else: bad(t, s)
  end

  defp decode({:named, t}, cell, _models) when t in @scalars, do: bad(t, cell)

  defp decode({:applied, "Option", [inner]} = type, cell, models) do
    if scalar?(inner) do
      with {:ok, v} <- decode(inner, cell, models), do: {:ok, {:var, "Option", "Some", [v]}}
    else
      from_json(type, cell, models)
    end
  end

  defp decode(type, cell, models), do: from_json(type, cell, models)

  # The stored value never reaches the message (`decode_row/4` logs the
  # detail): a JSON reason can quote the cell, a map key's text included.
  defp from_json(type, text, %{models: models, types: types}) when is_binary(text) do
    case Json.decode_stored(text, type, models, types) do
      {:ok, v} ->
        {:ok, v}

      {:error, why} ->
        {:error, "the stored value cannot be read as #{Format.type(type)}",
         "the stored JSON cannot be read: #{why}"}
    end
  end

  defp from_json(type, cell, _tables),
    do:
      {:error, "the stored value cannot be read as #{Format.type(type)}",
       "expected JSON text, the stored value is #{inspect(cell, limit: 5)}"}

  defp bad(t, cell) when is_binary(t), do: bad({:named, t}, cell)

  defp bad({:named, t}, cell),
    do:
      {:error, "the stored value is not a #{t}",
       "the stored value #{inspect(cell, limit: 5, printable_limit: 40)} is not a #{t}"}

  defp inspect_kind(v), do: Nobi.Lang.Rt.kind_name(v)
end
