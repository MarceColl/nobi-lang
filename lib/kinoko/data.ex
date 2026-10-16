defmodule Kinoko.Data do
  @moduledoc """
  Per-deployment storage: the rows of a deployment's stored models, in one
  SQLite file per deployment at `<data dir>/data/<deployment>.db` (the data
  dir is `Kinoko.Repo`'s; `dir:` overrides it, for tests).

  ## Opening

  `open/2` opens the file (creating it and the meta tables) and returns
  its `Kinoko.Data.Repo` pid. It is single-flight (`Kinoko.Data.Opener`).
  Every other call takes that pid and sets it as the dynamic repo for the
  call's duration, in the calling process only; a process that runs store
  work (an effect task, a transaction coordinator) is handed the pid.

  ## Rows

  A row is a record, `{:rec, model, %{field => value}}`, in the runtime's
  representation (`Kinoko.Lang.Rt`). `sig` is the model's signature as the
  running image has it, `[{field, type, default}]` (the image's
  `__yabu__(:models)` entry), or that whole models table, which a model
  with nested models needs to write and read them. Each call first makes
  sure of the table (`ensure/3`, cached), then:

  - `insert/4` mints a v4 Uuid as the row's id (any `"id"` the row has is
    overwritten) and appends the row;
  - `list/4` reads every row, in insertion order, capped at
    `max_rows/0` (`"too-many-rows"` above it);
  - `get/4`, `update/5` (whole-row replace; the row keeps its place) and
    `delete/4` work by id. A missing id is `nil` for `get` and `delete`,
    `"not-found"` for `update`.

  Writing and reading are type-directed (`Kinoko.Data.Codec`): a row
  written under an older signature reads under a newer one with the new
  fields' defaults, and columns a reader's signature lacks are ignored.

  ## Errors

  `{:error, %{code: code, message: message}}`:

  - `"unavailable"`: the file is busy or locked past `busy_timeout`, or
    the repo is gone (closed, crashed). Safe to retry.
  - `"store"`: a constraint failed, a value cannot be stored, or a stored
    value cannot be read as the reader's type. Never a wrong value.
  - `"too-many-rows"`, `"not-found"`: as above.

  `open/2` alone answers `{:error, :bad_name}` for a deployment name that
  is not one (`Kinoko.Universe.Registry.valid_name?/1`).
  """

  require Logger

  alias Kinoko.Data.{Codec, Opener, Repo, Schema}

  @max_rows 10_000

  @type repo :: pid()
  @type error :: %{code: String.t(), message: String.t()}
  @type sig :: [{String.t(), term(), term()}] | %{String.t() => list()}

  @doc "The most rows `list/4` returns."
  @spec max_rows() :: pos_integer()
  def max_rows, do: @max_rows

  # ---------- files ----------

  @doc "The file of `deployment`. Options: `dir:` (default: `Kinoko.Repo`'s directory)."
  @spec path(String.t(), keyword()) :: String.t()
  def path(deployment, opts \\ []) do
    dir = Keyword.get_lazy(opts, :dir, fn -> Kinoko.Release.data_dir(Kinoko.Repo) end)
    Path.join([dir, "data", deployment <> ".db"])
  end

  @doc """
  Opens `deployment`'s file, creating it if it is new; single-flight.
  Options: `dir:`, and `busy_timeout:` (ms), used only by the open that
  actually opens the file.
  """
  @spec open(String.t(), keyword()) :: {:ok, repo()} | {:error, :bad_name | term()}
  def open(deployment, opts \\ []) do
    if Kinoko.Universe.Registry.valid_name?(deployment),
      do: Opener.open(path(deployment, opts), opts),
      else: {:error, :bad_name}
  end

  @doc "Closes `deployment`'s file if it is open. Options: `dir:`."
  @spec close(String.t(), keyword()) :: :ok
  def close(deployment, opts \\ []) do
    if Kinoko.Universe.Registry.valid_name?(deployment),
      do: Opener.close(path(deployment, opts)),
      else: :ok
  end

  # ---------- schema ----------

  @doc "Creates `model`'s table, or adds the columns `sig` has and it lacks. Cached."
  @spec ensure(repo(), String.t(), sig()) :: :ok | {:error, error()}
  def ensure(repo, model, sig) do
    run(repo, fn ->
      with {:ok, _layout, _models} <- layout(repo, model, sig), do: :ok
    end)
  end

  # ---------- rows ----------

  @doc "Inserts `row`, with a fresh v4 id: `{:ok, id}`."
  @spec insert(repo(), String.t(), sig(), term()) ::
          {:ok, {:uuid, String.t()}} | {:error, error()}
  def insert(repo, model, sig, row) do
    run(repo, fn ->
      with {:ok, layout, models} <- layout(repo, model, sig),
           {:ok, cells} <- encode(model, layout, row, models) do
        id = Ecto.UUID.generate()
        t = Schema.quote_name(layout.table)
        cols = Enum.map_join(cells, "", fn {col, _} -> ", " <> Schema.quote_name(col) end)
        marks = String.duplicate(", ?", length(cells))

        Repo.query!(
          "INSERT INTO #{t} (id, _seq#{cols}) " <>
            "VALUES (?, (SELECT COALESCE(MAX(_seq), 0) + 1 FROM #{t})#{marks})",
          [id | Enum.map(cells, &elem(&1, 1))]
        )

        {:ok, {:uuid, id}}
      end
    end)
  end

  @doc """
  Every row, in insertion order. Above `max_rows/0` (or `cap:`) rows,
  `"too-many-rows"`.
  """
  @spec list(repo(), String.t(), sig(), keyword()) :: {:ok, [term()]} | {:error, error()}
  def list(repo, model, sig, opts \\ []) do
    cap = Keyword.get(opts, :cap, @max_rows)

    run(repo, fn ->
      with {:ok, layout, models} <- layout(repo, model, sig) do
        result =
          Repo.query!("#{select(layout)} ORDER BY _seq LIMIT ?", [cap + 1])

        if length(result.rows) > cap do
          error(
            "too-many-rows",
            "#{model} has more than #{cap} rows, more than a list reads at once"
          )
        else
          decode_all(model, layout, result, models)
        end
      end
    end)
  end

  @doc "The row with `id`, or `nil`."
  @spec get(repo(), String.t(), sig(), {:uuid, String.t()}) ::
          {:ok, term() | nil} | {:error, error()}
  def get(repo, model, sig, id) do
    run(repo, fn ->
      with {:ok, text} <- id_text(id),
           {:ok, layout, models} <- layout(repo, model, sig) do
        fetch(model, layout, text, models)
      end
    end)
  end

  @doc "Replaces the row with `id` by `row` (its id kept): `{:ok, id}`; `\"not-found\"` if none."
  @spec update(repo(), String.t(), sig(), {:uuid, String.t()}, term()) ::
          {:ok, {:uuid, String.t()}} | {:error, error()}
  def update(repo, model, sig, id, row) do
    run(repo, fn ->
      with {:ok, text} <- id_text(id),
           {:ok, layout, models} <- layout(repo, model, sig),
           {:ok, cells} <- encode(model, layout, row, models) do
        sets =
          Enum.map_join(cells, ", ", fn {col, _} -> Schema.quote_name(col) <> " = ?" end)

        result =
          if cells == [] do
            Repo.query!("SELECT 1 FROM #{Schema.quote_name(layout.table)} WHERE id = ?", [text])
          else
            Repo.query!(
              "UPDATE #{Schema.quote_name(layout.table)} SET #{sets} WHERE id = ?",
              Enum.map(cells, &elem(&1, 1)) ++ [text]
            )
          end

        if result.num_rows == 0,
          do: error("not-found", "#{model} has no row with id #{text}"),
          else: {:ok, id}
      end
    end)
  end

  @doc """
  Deletes the row with `id`: `{:ok, row}` (as it was), or `{:ok, nil}` if
  there is none. A row that cannot be read is not deleted (`"store"`).
  """
  @spec delete(repo(), String.t(), sig(), {:uuid, String.t()}) ::
          {:ok, term() | nil} | {:error, error()}
  def delete(repo, model, sig, id) do
    run(repo, fn ->
      with {:ok, text} <- id_text(id),
           {:ok, layout, models} <- layout(repo, model, sig) do
        transaction(fn ->
          case fetch(model, layout, text, models) do
            {:ok, nil} ->
              nil

            {:ok, row} ->
              Repo.query!("DELETE FROM #{Schema.quote_name(layout.table)} WHERE id = ?", [text])
              row

            {:error, error} ->
              Repo.rollback(error)
          end
        end)
      end
    end)
  end

  # ---------- console ----------

  @doc """
  The deployment's models, for the console: `[%{model, table, rows,
  columns: [%{name, field, type}]}]`, by model name (`field` is `nil` for
  `id` and `_seq`). A deployment with no file has none (and gets none).
  Options: `dir:`.
  """
  @spec stats(String.t(), keyword()) :: [map()]
  def stats(deployment, opts \\ []) do
    with true <- Kinoko.Universe.Registry.valid_name?(deployment),
         true <- File.exists?(path(deployment, opts)),
         {:ok, repo} <- open(deployment, opts),
         {:ok, stats} <- run(repo, &table_stats/0) do
      stats
    else
      {:error, reason} ->
        Logger.warning("Kinoko.Data.stats(#{deployment}): #{inspect(reason)}")
        []

      _ ->
        []
    end
  end

  defp table_stats do
    tables = Repo.query!("SELECT symbol, tbl FROM _kinoko_tables ORDER BY symbol").rows

    stats =
      for [model, table] <- tables do
        t = Schema.quote_name(table)
        [[rows]] = Repo.query!("SELECT COUNT(*) FROM #{t}").rows

        fields =
          Map.new(
            Repo.query!("SELECT col, field FROM _kinoko_columns WHERE tbl = ?", [table]).rows,
            &List.to_tuple/1
          )

        columns =
          for [_cid, name, type | _] <- Repo.query!("PRAGMA table_info(#{t})").rows do
            %{name: name, field: Map.get(fields, name), type: type}
          end

        %{model: model, table: table, rows: rows, columns: columns}
      end

    {:ok, stats}
  end

  # ---------- transactions ----------

  @doc """
  Runs `fun` in one `IMMEDIATE` transaction on `repo`'s file, in the
  calling process: `{:ok, value}`, or `{:error, reason}` when `fun` calls
  `rollback/1` or raises (an error raised by SQLite is classified as the
  other calls classify it). The calls `fun` makes on `repo` join it.

  A joined call that fails *inside its own nested transaction* marks this
  one for rollback, even though it returns an ordinary `{:error, _}` to
  `fun`: a schema sync that fails (a name that cannot be given), and a
  `delete/4` of a row that cannot be read. `fun` may carry on, but nothing
  it writes is kept: the transaction answers `{:error, :rollback}`.

  A schema sync done inside the transaction is not cached (a rollback
  would undo it), so the next call outside syncs again.
  """
  @spec transaction(repo(), (-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(repo, fun), do: run(repo, fn -> transaction(fun) end)

  @doc "Rolls back the transaction `transaction/2` is running, which answers `{:error, value}`."
  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback(value)

  defp transaction(fun), do: Repo.transaction(fun)

  # ---------- internals ----------

  # Runs `fun` with `repo` as this process's dynamic repo, restoring the
  # previous one after; SQLite errors and a gone repo become error tuples.
  defp run(repo, fun) do
    if Process.alive?(repo) do
      previous = Repo.get_dynamic_repo()
      Repo.put_dynamic_repo(repo)

      try do
        fun.()
      rescue
        e in Exqlite.Error ->
          {:error, sql_error(e)}

        e in DBConnection.ConnectionError ->
          unavailable(Exception.message(e))

        # Ecto's lookup of a repo pid that died since the liveness check.
        e in RuntimeError ->
          if String.starts_with?(e.message, "could not lookup Ecto repo"),
            do: unavailable(e.message),
            else: reraise(e, __STACKTRACE__)
      catch
        :exit, reason -> unavailable("the store stopped: #{inspect(reason, limit: 5)}")
      after
        Repo.put_dynamic_repo(previous)
      end
    else
      unavailable("the deployment's store is closed")
    end
  end

  defp sql_error(%Exqlite.Error{message: message}) do
    text = String.downcase(message || "")

    code =
      if String.contains?(text, "locked") or String.contains?(text, "busy"),
        do: "unavailable",
        else: "store"

    %{code: code, message: message}
  end

  defp unavailable(message), do: {:error, %{code: "unavailable", message: message}}

  defp error(code, message), do: {:error, %{code: code, message: message}}

  defp store_error(message), do: error("store", message)

  defp layout(repo, model, sig) do
    models = if is_list(sig), do: %{model => sig}, else: sig

    case Map.fetch(models, model) do
      {:ok, fields} when is_list(fields) ->
        case Schema.layout(repo, model, fields) do
          {:ok, layout} -> {:ok, layout, models}
          {:error, why} -> store_error(why)
        end

      _ ->
        store_error("#{model} is not a model of the given signatures")
    end
  end

  defp encode(model, layout, row, models) do
    case Codec.encode_row(model, layout.columns, row, models) do
      {:ok, cells} -> {:ok, cells}
      {:error, why} -> store_error(why)
    end
  end

  defp select(layout) do
    cols =
      Enum.map_join(layout.columns, "", fn {_, _, _, col} -> ", " <> Schema.quote_name(col) end)

    "SELECT id#{cols} FROM #{Schema.quote_name(layout.table)}"
  end

  defp fetch(model, layout, text, models) do
    case Repo.query!("#{select(layout)} WHERE id = ?", [text]) do
      %{rows: []} -> {:ok, nil}
      result -> with {:ok, [row]} <- decode_all(model, layout, result, models), do: {:ok, row}
    end
  end

  defp decode_all(model, layout, %{columns: names, rows: rows}, models) do
    Enum.reduce_while(rows, {:ok, []}, fn cells, {:ok, acc} ->
      case Codec.decode_row(model, layout.columns, Map.new(Enum.zip(names, cells)), models) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, why} -> {:halt, store_error(why)}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp id_text({:uuid, text} = id) do
    if Codec.uuid_text?(text), do: {:ok, text}, else: store_error("#{inspect(id)} is not a Uuid")
  end

  defp id_text(id), do: store_error("an id must be a Uuid, got #{Kinoko.Lang.Rt.kind_name(id)}")
end
