defmodule Nobi.Data.Schema do
  @moduledoc """
  A deployment file's tables: names, column types, and keeping a model's
  table in step with its signature (`ensure/3`).

  ## Names

  A model's table is its symbol lowercased, `.` as `__` (`Forum.Post` →
  `forum__post`). A field's column is the field's name. A name outside
  `[a-z0-9_]`, one SQLite reserves (`sqlite_…`), one of ours (`_nobi_…`,
  `_seq`) or one another symbol of the file already has falls back to
  `fallback/1`: `m_` and the first 12 hex of the symbol's sha256.

  Every mapping is recorded, in `_nobi_tables(symbol, tbl, seq)` and
  `_nobi_columns(tbl, field, col, stype)`, and read back from there: a
  table's name, once given, never changes, and a field keeps its column
  while its storage type does. Names are strings throughout; none becomes
  an atom.

  ## Storage types

  A column holds the values of one storage type (`storage_type/1`): `Int`,
  `Float`, `Bool`, `String` or `Uuid` (an `Option` of one shares it), or `JSON` and
  the field's whole type. It is recorded with the column. A field whose
  type changes (a model removed and declared again under its name) never
  reads the old column as the new type: SQLite would coerce (`"0042"` into
  an `INTEGER` column is `42`), and `1` is as good a `Bool` as an `Int`.
  Instead the old column is retired, untouched (`_nobi_retired(tbl,
  field, stype, col)`), and the field moves to a column of its own:
  `<col>__v2` (`__v3`, …), or the column it had with that storage type
  before, if it had one. Rows written before the change read the field as
  absent (its default, `None`, or an error, as for any absent field).

  A file from before storage types has its columns marked `legacy:` and
  their SQL type at open (`create_meta/1`); the first sync that finds one
  adopts it for a field of that SQL type, and retires it for any other.

  ## Columns

  `id TEXT PRIMARY KEY` and `_seq INTEGER NOT NULL` (insertion order,
  indexed), then one per field: `Int`/`Bool` → `INTEGER`, `Float` → `REAL`,
  `String`/`Uuid` → `TEXT`, `Option` of one of those → that type, nullable; anything else →
  `TEXT` holding canonical JSON (`Nobi.Data.Codec`). Every field column is
  nullable and has no SQL `DEFAULT`: defaults are read-time, from the
  reader's signature (a `NULL` in a non-`Option` column is "absent").

  ## Insertion order

  `_seq` orders a table's rows, and is never reused: `next_seq/1` takes
  it from the table's counter in `_nobi_tables.seq`, in the inserting
  transaction, so a deleted newest row's number is not handed out again.

  ## Sync

  `layout/3` first reads: a table that has every field's column with the
  field's storage type is used as it is, with no write lock and no write
  transaction. Otherwise it syncs, under the deployment's write lock
  (`Nobi.Data.Lock`), in one `IMMEDIATE` transaction: it creates the
  table, and adds (`ALTER TABLE … ADD COLUMN`) each column a field lacks
  (rows already there, and rows inserted by code that predates the field,
  hold `NULL` there). It never drops or alters a column. Its layout is cached per `{repo, model, signature
  hash}` (`Nobi.Data.Cache`). Inside an enclosing transaction
  (`Nobi.Data.transaction/2`) a rollback would undo the table or
  columns the cache would claim, so there the layout is deferred: kept
  for the rest of the transaction and cached only once it commits
  (`Nobi.Data.Cache`'s "Deferred entries").
  """

  alias Nobi.Data.{Cache, Codec, Lock, Repo}
  alias Nobi.Lang.Format

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
    do: String.starts_with?(name, "sqlite_") or String.starts_with?(name, "_nobi_")

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

  @doc """
  Creates the meta tables of the file `repo` is open on, if missing, and
  brings an older file's up to date (see "Storage types" and "Insertion
  order"), in one transaction. Runs once per open (`Nobi.Data.Opener`).
  """
  @spec create_meta(pid()) :: :ok | {:error, term()}
  def create_meta(repo) do
    Repo.put_dynamic_repo(repo)

    {:ok, :ok} =
      Repo.transaction(fn ->
        rename_legacy_meta()

        Repo.query!(
          "CREATE TABLE IF NOT EXISTS _nobi_tables " <>
            "(symbol TEXT PRIMARY KEY, tbl TEXT NOT NULL UNIQUE, seq INTEGER)"
        )

        Repo.query!(
          "CREATE TABLE IF NOT EXISTS _nobi_columns (tbl TEXT NOT NULL, field TEXT NOT NULL, " <>
            "col TEXT NOT NULL, stype TEXT, PRIMARY KEY (tbl, field), UNIQUE (tbl, col))"
        )

        Repo.query!(
          "CREATE TABLE IF NOT EXISTS _nobi_retired (tbl TEXT NOT NULL, field TEXT NOT NULL, " <>
            "stype TEXT NOT NULL, col TEXT NOT NULL, PRIMARY KEY (tbl, field, stype))"
        )

        add_meta_column("_nobi_tables", "seq", "INTEGER")
        add_meta_column("_nobi_columns", "stype", "TEXT")
        mark_legacy_columns()
        :ok
      end)

    :ok
  rescue
    e -> {:error, e}
  end

  # The project was called Kinoko: a file written before the rename has
  # its meta tables and `_seq` indexes under `_kinoko_`. They take the new
  # names in place, once; nothing else about them changes.
  defp rename_legacy_meta do
    tables = MapSet.new(sqlite_names("table"))

    if "_kinoko_tables" in tables and "_nobi_tables" not in tables do
      for meta <- ~w(tables columns retired), ("_kinoko_" <> meta) in tables do
        Repo.query!("ALTER TABLE _kinoko_#{meta} RENAME TO _nobi_#{meta}")
      end
    end

    for [index, table] <-
          Repo.query!(
            "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index' " <>
              "AND name GLOB '_kinoko_seq_*'"
          ).rows do
      Repo.query!("DROP INDEX #{quote_name(index)}")
      create_seq_index(table)
    end

    :ok
  end

  defp sqlite_names(type),
    do: List.flatten(Repo.query!("SELECT name FROM sqlite_master WHERE type = ?", [type]).rows)

  defp add_meta_column(table, col, type) do
    unless col in column_names(table) do
      Repo.query!("ALTER TABLE #{table} ADD COLUMN #{col} #{type}")
    end
  end

  # A column recorded before storage types were: `legacy:` and its SQL
  # type, all that is known of it (see "Storage types").
  defp mark_legacy_columns do
    tables = Repo.query!("SELECT DISTINCT tbl FROM _nobi_columns WHERE stype IS NULL").rows

    for [table] <- tables do
      declared = declared_types(table)

      for [col] <- Repo.query!(legacy_cols(), [table]).rows do
        Repo.query!(
          "UPDATE _nobi_columns SET stype = ? WHERE tbl = ? AND col = ?",
          ["legacy:" <> Map.get(declared, col, ""), table, col]
        )
      end
    end
  end

  defp legacy_cols, do: "SELECT col FROM _nobi_columns WHERE tbl = ? AND stype IS NULL"

  defp column_names(table), do: Map.keys(declared_types(table))

  # `%{column => declared SQL type}` of `table` (empty if it has none).
  defp declared_types(table) do
    Map.new(Repo.query!("PRAGMA table_info(#{quote_name(table)})").rows, fn row ->
      {row |> Enum.at(1) |> String.downcase(), Enum.at(row, 2)}
    end)
  end

  # ---------- storage types ----------

  @doc """
  The storage type of a field of `type`: what its column's cells hold, so
  what they can be read as (see "Storage types"). `Option` of a scalar
  shares its scalar's.
  """
  @spec storage_type(term()) :: String.t()
  def storage_type({:named, t}) when t in ["Int", "Float", "Bool", "String", "Uuid"], do: t

  def storage_type({:applied, "Option", [inner]} = type) do
    if Codec.scalar?(inner), do: storage_type(inner), else: "JSON " <> Format.type(type)
  end

  def storage_type(type), do: "JSON " <> Format.type(type)

  # A column recorded as `recorded` holds values a field of storage type
  # `stype` reads: the same storage type, or a legacy column of the same
  # SQL type (all an older file tells).
  defp holds?(recorded, stype, type),
    do: recorded == stype or recorded == "legacy:" <> column_type(type)

  # ---------- ensure ----------

  @doc """
  The layout of `model`'s table under its `fields` (`[{field, type,
  default}]`), the table synced first if this repo has not synced it for
  this signature. Runs in the caller, whose dynamic repo is set; raises
  `Exqlite.Error` as a query does (and `Nobi.Data.LockError` when the
  write lock cannot be had), and returns `{:error, message}` for a name
  that cannot be given. Inside an enclosing transaction, that error also
  marks the enclosing one for rollback.

  A table that already matches the signature is read, never written: no
  write lock, no write transaction (`matching/2`).
  """
  @spec layout(pid(), String.t(), list()) :: {:ok, layout()} | {:error, String.t()}
  def layout(repo, model, fields) do
    key = {repo, model, :erlang.phash2(fields, 4_294_967_296)}

    case Cache.get(key) do
      {:ok, {^fields, layout}} ->
        {:ok, layout}

      _ ->
        # Checked before `sync/3` opens its own transaction: only an
        # enclosing one can roll the sync back after it returns.
        if Repo.in_transaction?(),
          do: enclosed_layout(repo, key, model, fields),
          else: synced(repo, key, model, fields)
    end
  end

  defp synced(repo, key, model, fields) do
    with {:ok, layout} <- sync(repo, model, fields) do
      Cache.put(key, {fields, layout})
      {:ok, layout}
    end
  end

  # Inside a transaction: deferred until it commits (`Cache.defer/2`).
  defp enclosed_layout(repo, key, model, fields) do
    case Cache.deferred(key) do
      {:ok, {^fields, layout}} ->
        {:ok, layout}

      _ ->
        with {:ok, layout} <- sync(repo, model, fields) do
          Cache.defer(key, {fields, layout})
          {:ok, layout}
        end
    end
  end

  defp sync(repo, model, fields) do
    case matching(model, fields) do
      {:ok, layout} -> {:ok, layout}
      :no -> Lock.with_lock(repo, fn -> write_sync(model, fields) end)
    end
  end

  # The layout read off the file when the table and every field's column
  # are there with the field's storage type: reads only.
  defp matching(model, fields) do
    with [[table]] <- Repo.query!("SELECT tbl FROM _nobi_tables WHERE symbol = ?", [model]).rows,
         mapped = recorded_columns(table),
         present = MapSet.new(column_names(table)),
         columns when is_list(columns) <- matching_columns(fields, mapped, present) do
      {:ok, %{table: table, columns: columns}}
    else
      _ -> :no
    end
  end

  defp matching_columns(fields, mapped, present) do
    Enum.reduce_while(stored_fields(fields), [], fn {field, type, default}, acc ->
      case Map.fetch(mapped, field) do
        {:ok, {col, stype}} ->
          if stype == storage_type(type) and MapSet.member?(present, col),
            do: {:cont, [{field, type, default, col} | acc]},
            else: {:halt, :no}

        :error ->
          {:halt, :no}
      end
    end)
    |> case do
      :no -> :no
      columns -> Enum.reverse(columns)
    end
  end

  defp stored_fields(fields), do: Enum.reject(fields, fn {field, _, _} -> field == "id" end)

  # `%{field => {col, stype}}` of `table`.
  defp recorded_columns(table) do
    Map.new(
      Repo.query!("SELECT field, col, stype FROM _nobi_columns WHERE tbl = ?", [table]).rows,
      fn [field, col, stype] -> {field, {col, stype}} end
    )
  end

  defp write_sync(model, fields) do
    tx =
      Repo.transaction(fn ->
        with {:ok, table} <- table_for(model),
             :ok <- create_table(table),
             {:ok, columns} <- columns_for(table, fields) do
          %{table: table, columns: columns}
        else
          {:error, why} -> Repo.rollback(why)
        end
      end)

    case tx do
      {:ok, layout} -> {:ok, layout}
      {:error, why} when is_binary(why) -> {:error, "#{model}: #{why}"}
      {:error, why} -> {:error, "#{model}: #{inspect(why)}"}
    end
  end

  defp table_for(symbol) do
    case Repo.query!("SELECT tbl FROM _nobi_tables WHERE symbol = ?", [symbol]).rows do
      [[table]] ->
        {:ok, table}

      [] ->
        wanted = table_name(symbol)

        candidates =
          if table_taken?(wanted), do: [fallback(symbol)], else: [wanted]

        case Enum.reject(candidates, &table_taken?/1) do
          [table | _] ->
            Repo.query!("INSERT INTO _nobi_tables (symbol, tbl) VALUES (?, ?)", [symbol, table])
            {:ok, table}

          [] ->
            {:error, "no table name is free for it (#{wanted}, #{fallback(symbol)})"}
        end
    end
  end

  defp table_taken?(table),
    do: Repo.query!("SELECT 1 FROM _nobi_tables WHERE tbl = ?", [table]).rows != []

  defp create_table(table) do
    t = quote_name(table)

    Repo.query!("CREATE TABLE IF NOT EXISTS #{t} (id TEXT PRIMARY KEY, _seq INTEGER NOT NULL)")

    create_seq_index(table)
  end

  # Index and table names share one namespace; `_nobi_` is never a table's.
  defp create_seq_index(table) do
    index = quote_name("_nobi_seq_" <> table)
    Repo.query!("CREATE INDEX IF NOT EXISTS #{index} ON #{quote_name(table)} (_seq)")
    :ok
  end

  defp columns_for(table, fields) do
    state = %{
      table: table,
      mapped: recorded_columns(table),
      present: MapSet.new(column_names(table))
    }

    fields
    |> stored_fields()
    |> Enum.reduce_while({:ok, [], state}, fn {field, type, default}, {:ok, acc, state} ->
      case column_for(state, field, type) do
        {:ok, col, state} -> {:cont, {:ok, [{field, type, default, col} | acc], state}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, columns, _} -> {:ok, Enum.reverse(columns)}
      error -> error
    end
  end

  # The column of `field` as a `type`: its recorded one if that holds this
  # storage type, else a column of its own (see "Storage types").
  defp column_for(state, field, type) do
    stype = storage_type(type)

    case Map.fetch(state.mapped, field) do
      {:ok, {col, recorded}} ->
        if holds?(recorded, stype, type) do
          if recorded != stype, do: record_stype(state.table, field, stype)
          {:ok, col, add_column(state, col, type)}
        else
          retype(state, field, {col, recorded}, stype, type)
        end

      :error ->
        candidates = [column_name(field), fallback(field)]

        case Enum.reject(candidates, &taken?(state, &1)) do
          [col | _] ->
            Repo.query!(
              "INSERT INTO _nobi_columns (tbl, field, col, stype) VALUES (?, ?, ?, ?)",
              [state.table, field, col, stype]
            )

            {:ok, col, state |> map(field, col, stype) |> add_column(col, type)}

          [] ->
            {:error, "no column name is free for `#{field}`"}
        end
    end
  end

  # `field`'s type changed: its column is retired, untouched, and the field
  # moves to the column it had with this storage type before, if any, or
  # to a fresh one (`col__v2`, `col__v3`, …).
  defp retype(state, field, {old, recorded}, stype, type) do
    Repo.query!(
      "INSERT OR REPLACE INTO _nobi_retired (tbl, field, stype, col) VALUES (?, ?, ?, ?)",
      [state.table, field, recorded, old]
    )

    # A column retired with this storage type, or a legacy one that holds it.
    retired =
      Repo.query!(
        "SELECT stype, col FROM _nobi_retired WHERE tbl = ? AND field = ? AND stype IN (?, ?) " <>
          "ORDER BY stype = ? DESC LIMIT 1",
        [state.table, field, stype, "legacy:" <> column_type(type), stype]
      ).rows

    col =
      case retired do
        [[was, col]] ->
          Repo.query!("DELETE FROM _nobi_retired WHERE tbl = ? AND field = ? AND stype = ?", [
            state.table,
            field,
            was
          ])

          col

        [] ->
          fresh(state, old)
      end

    with col when is_binary(col) <- col do
      Repo.query!("UPDATE _nobi_columns SET col = ?, stype = ? WHERE tbl = ? AND field = ?", [
        col,
        stype,
        state.table,
        field
      ])

      {:ok, col, state |> map(field, col, stype) |> add_column(col, type)}
    end
  end

  defp fresh(state, old) do
    Enum.find_value(2..1_000, {:error, "no column name is free for a retyped `#{old}`"}, fn n ->
      col = "#{old}__v#{n}"
      if taken?(state, col), do: nil, else: col
    end)
  end

  defp record_stype(table, field, stype) do
    Repo.query!("UPDATE _nobi_columns SET stype = ? WHERE tbl = ? AND field = ?", [
      stype,
      table,
      field
    ])
  end

  # A name another field holds, or a column the table has (a retired one).
  defp taken?(state, col) do
    col in @reserved_columns or MapSet.member?(state.present, col) or
      Enum.any?(state.mapped, fn {_, {c, _}} -> c == col end)
  end

  defp map(state, field, col, stype),
    do: %{state | mapped: Map.put(state.mapped, field, {col, stype})}

  # No SQL `DEFAULT`: a NULL (or absent) cell means "absent", and reads as
  # the field's default in the reader's signature (`Nobi.Data.Codec`), so
  # a changed default applies to every row written before the field.
  defp add_column(state, col, type) do
    if MapSet.member?(state.present, col) do
      state
    else
      Repo.query!(
        "ALTER TABLE #{quote_name(state.table)} ADD COLUMN #{quote_name(col)} " <>
          column_type(type)
      )

      %{state | present: MapSet.put(state.present, col)}
    end
  end

  # ---------- insertion order ----------

  @doc """
  The next `_seq` of `table`: one past every `_seq` it ever issued, kept
  in `_nobi_tables.seq` (and past every `_seq` in the table, for a file
  from before the counter). Must run in the transaction that inserts
  the row, so a rollback takes the number back with the row.
  """
  @spec next_seq(String.t()) :: pos_integer()
  def next_seq(table) do
    %{rows: [[seq]]} =
      Repo.query!(
        "UPDATE _nobi_tables SET seq = MAX(COALESCE(seq, 0), " <>
          "(SELECT COALESCE(MAX(_seq), 0) FROM #{quote_name(table)})) + 1 " <>
          "WHERE tbl = ? RETURNING seq",
        [table]
      )

    seq
  end

  @doc "The SQLite column type of a field of `type` (see \"Columns\")."
  @spec column_type(term()) :: String.t()
  def column_type({:named, t}) when t in ["Int", "Bool"], do: "INTEGER"
  def column_type({:named, "Float"}), do: "REAL"
  def column_type({:named, t}) when t in ["String", "Uuid"], do: "TEXT"

  def column_type({:applied, "Option", [inner]}) do
    if Codec.scalar?(inner), do: column_type(inner), else: "TEXT"
  end

  def column_type(_), do: "TEXT"
end
