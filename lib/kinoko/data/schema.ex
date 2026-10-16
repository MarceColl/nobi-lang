defmodule Kinoko.Data.Schema do
  @moduledoc """
  A deployment file's tables: names, column types, and keeping a model's
  table in step with its signature (`ensure/3`).

  ## Names

  A model's table is its symbol lowercased, `.` as `__` (`Forum.Post` →
  `forum__post`). A field's column is the field's name. A name outside
  `[a-z0-9_]`, one SQLite reserves (`sqlite_…`), one of ours (`_kinoko_…`,
  `_seq`) or one another symbol of the file already has falls back to
  `fallback/1`: `m_` and the first 12 hex of the symbol's sha256.

  Every mapping is recorded, in `_kinoko_tables(symbol, tbl)` and
  `_kinoko_columns(tbl, field, col)`, and read back from there: a name, once
  given, never changes. Names are strings throughout; none becomes an atom.

  ## Columns

  `id TEXT PRIMARY KEY` and `_seq INTEGER NOT NULL` (insertion order,
  indexed), then one per field: `Int`/`Bool` → `INTEGER`, `String`/`Uuid` →
  `TEXT`, `Option` of one of those → that type, nullable; anything else →
  `TEXT` holding canonical JSON (`Kinoko.Data.Codec`). Every field column is
  nullable.

  ## Sync

  `ensure/3` creates the table, and adds (`ALTER TABLE … ADD COLUMN`) each
  field the table lacks, with a `DEFAULT` of the field's default when it has
  one (so rows already there, and rows inserted by code that predates the
  field, read it). It never drops or alters a column. It runs in one
  `IMMEDIATE` transaction, so concurrent ensures of one file serialize. Its
  layout is cached per `{repo, model, signature hash}` (`Kinoko.Data.Cache`).
  """

  alias Kinoko.Data.{Cache, Codec, Repo}

  @typedoc "A field's place: `{field, type, default, column}`."
  @type column :: {String.t(), term(), term(), String.t()}
  @type layout :: %{table: String.t(), columns: [column()]}

  @plain ~r/\A[a-z0-9_]+\z/
  @reserved_columns ["id", "_seq"]

  # ---------- names ----------

  @doc "`m_` and the first 12 hex of `symbol`'s sha256."
  @spec fallback(String.t()) :: String.t()
  def fallback(symbol) do
    hex = :crypto.hash(:sha256, symbol) |> Base.encode16(case: :lower)
    "m_" <> binary_part(hex, 0, 12)
  end

  @doc "The table a model's symbol asks for, before collisions (see \"Names\")."
  @spec table_name(String.t()) :: String.t()
  def table_name(symbol) do
    name = symbol |> String.downcase() |> String.replace(".", "__")

    if Regex.match?(@plain, name) and not reserved_table?(name),
      do: name,
      else: fallback(symbol)
  end

  defp reserved_table?(name),
    do: String.starts_with?(name, "sqlite_") or String.starts_with?(name, "_kinoko_")

  @doc "The column a field asks for, before collisions (see \"Names\")."
  @spec column_name(String.t()) :: String.t()
  def column_name(field) do
    if Regex.match?(@plain, field) and field not in @reserved_columns,
      do: field,
      else: fallback(field)
  end

  @doc "`name` quoted as an SQL identifier."
  @spec quote_name(String.t()) :: String.t()
  def quote_name(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  # ---------- meta tables ----------

  @doc "Creates the meta tables of the file `repo` is open on, if missing."
  @spec create_meta(pid()) :: :ok | {:error, term()}
  def create_meta(repo) do
    Repo.put_dynamic_repo(repo)

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS _kinoko_tables " <>
        "(symbol TEXT PRIMARY KEY, tbl TEXT NOT NULL UNIQUE)"
    )

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS _kinoko_columns (tbl TEXT NOT NULL, field TEXT NOT NULL, " <>
        "col TEXT NOT NULL, PRIMARY KEY (tbl, field), UNIQUE (tbl, col))"
    )

    :ok
  rescue
    e -> {:error, e}
  end

  # ---------- ensure ----------

  @doc """
  The layout of `model`'s table under its `fields` (`[{field, type,
  default}]`), the table synced first if this repo has not synced it for
  this signature. Runs in the caller, whose dynamic repo is set; raises
  `Exqlite.Error` as a query does, and returns `{:error, message}` for a
  default that cannot be stored or a name that cannot be given.
  """
  @spec layout(pid(), String.t(), list(), map()) :: {:ok, layout()} | {:error, String.t()}
  def layout(repo, model, fields, models) do
    key = {repo, model, :erlang.phash2(fields, 4_294_967_296)}

    case Cache.get(key) do
      {:ok, {^fields, layout}} ->
        {:ok, layout}

      _ ->
        with {:ok, layout} <- sync(model, fields, models) do
          Cache.put(key, {fields, layout})
          {:ok, layout}
        end
    end
  end

  defp sync(model, fields, models) do
    tx =
      Repo.transaction(fn ->
        with {:ok, table} <- table_for(model),
             :ok <- create_table(table),
             {:ok, columns} <- columns_for(table, fields, models) do
          %{table: table, columns: columns}
        else
          {:error, why} -> Repo.rollback(why)
        end
      end)

    case tx do
      {:ok, layout} -> {:ok, layout}
      {:error, why} when is_binary(why) -> {:error, "#{model}: #{why}"}
    end
  end

  defp table_for(symbol) do
    case Repo.query!("SELECT tbl FROM _kinoko_tables WHERE symbol = ?", [symbol]).rows do
      [[table]] ->
        {:ok, table}

      [] ->
        wanted = table_name(symbol)

        candidates =
          if table_taken?(wanted), do: [fallback(symbol)], else: [wanted]

        case Enum.reject(candidates, &table_taken?/1) do
          [table | _] ->
            Repo.query!("INSERT INTO _kinoko_tables (symbol, tbl) VALUES (?, ?)", [symbol, table])
            {:ok, table}

          [] ->
            {:error, "no table name is free for it (#{wanted}, #{fallback(symbol)})"}
        end
    end
  end

  defp table_taken?(table),
    do: Repo.query!("SELECT 1 FROM _kinoko_tables WHERE tbl = ?", [table]).rows != []

  defp create_table(table) do
    t = quote_name(table)

    Repo.query!("CREATE TABLE IF NOT EXISTS #{t} (id TEXT PRIMARY KEY, _seq INTEGER NOT NULL)")

    # Index and table names share one namespace; `_kinoko_` is never a table's.
    index = quote_name("_kinoko_seq_" <> table)
    Repo.query!("CREATE INDEX IF NOT EXISTS #{index} ON #{t} (_seq)")
    :ok
  end

  defp columns_for(table, fields, models) do
    mapped =
      Map.new(
        Repo.query!("SELECT field, col FROM _kinoko_columns WHERE tbl = ?", [table]).rows,
        &List.to_tuple/1
      )

    present =
      MapSet.new(Repo.query!("PRAGMA table_info(#{quote_name(table)})").rows, fn row ->
        row |> Enum.at(1) |> String.downcase()
      end)

    fields
    |> Enum.reject(fn {field, _, _} -> field == "id" end)
    |> Enum.reduce_while({:ok, [], mapped}, fn {field, type, default}, {:ok, acc, mapped} ->
      with {:ok, col, mapped} <- column_for(table, field, mapped),
           :ok <- add_column(table, col, present, field, type, default, models) do
        {:cont, {:ok, [{field, type, default, col} | acc], mapped}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, columns, _} -> {:ok, Enum.reverse(columns)}
      error -> error
    end
  end

  defp column_for(table, field, mapped) do
    case Map.fetch(mapped, field) do
      {:ok, col} ->
        {:ok, col, mapped}

      :error ->
        taken = MapSet.new(@reserved_columns ++ Map.values(mapped))
        wanted = column_name(field)

        case Enum.reject([wanted, fallback(field)], &MapSet.member?(taken, &1)) do
          [col | _] ->
            Repo.query!("INSERT INTO _kinoko_columns (tbl, field, col) VALUES (?, ?, ?)", [
              table,
              field,
              col
            ])

            {:ok, col, Map.put(mapped, field, col)}

          [] ->
            {:error, "no column name is free for `#{field}`"}
        end
    end
  end

  defp add_column(table, col, present, field, type, default, models) do
    if MapSet.member?(present, col) do
      :ok
    else
      with {:ok, default_sql} <- default_clause(field, type, default, models) do
        Repo.query!(
          "ALTER TABLE #{quote_name(table)} ADD COLUMN #{quote_name(col)} " <>
            column_type(type) <> default_sql
        )

        :ok
      end
    end
  end

  defp default_clause(_field, _type, :none, _models), do: {:ok, ""}

  defp default_clause(field, type, default, models) do
    case Codec.encode(type, default, models) do
      {:ok, nil} -> {:ok, ""}
      {:ok, n} when is_integer(n) -> {:ok, " DEFAULT " <> Integer.to_string(n)}
      {:ok, s} when is_binary(s) -> {:ok, " DEFAULT " <> quote_literal(s)}
      {:error, why} -> {:error, "the default of `#{field}` cannot be stored: #{why}"}
    end
  end

  defp quote_literal(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  @doc "The SQLite column type of a field of `type` (see \"Columns\")."
  @spec column_type(term()) :: String.t()
  def column_type({:named, t}) when t in ["Int", "Bool"], do: "INTEGER"
  def column_type({:named, t}) when t in ["String", "Uuid"], do: "TEXT"

  def column_type({:applied, "Option", [inner]}) do
    if Codec.scalar?(inner), do: column_type(inner), else: "TEXT"
  end

  def column_type(_), do: "TEXT"
end
