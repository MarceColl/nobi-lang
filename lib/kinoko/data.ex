defmodule Kinoko.Data do
  @moduledoc """
  Per-deployment storage: the rows of a deployment's stored models, in one
  SQLite file per deployment at `<data dir>/data/<deployment>.db` (the data
  dir is `Kinoko.Repo`'s; `dir:`, or the application env's
  `config :kinoko, Kinoko.Data, dir: ...`, overrides it, for tests).

  ## Opening

  `open/2` opens the file (creating it and the meta tables) and returns
  its `Kinoko.Data.Repo` pid. It is single-flight (`Kinoko.Data.Opener`).
  Every other call takes that pid and sets it as the dynamic repo for the
  call's duration, in the calling process only; a process that runs store
  work (an effect task, a transaction coordinator) is handed the pid.

  ## Writers and readers

  Every write (`insert/4`, `update/5`, `delete/4`, `transaction/2`, and a
  schema sync) takes the deployment's write lock (`Kinoko.Data.Lock`)
  before it checks out a connection, so a writer waiting its turn holds
  none and reads (WAL) never wait behind writers. Reads take no lock.

  ## Rows

  A row is a record, `{:rec, model, %{field => value}}`, in the runtime's
  representation (`Kinoko.Lang.Rt`). `sig` is the model's signature as the
  running image has it, `[{field, type, default}]` (the image's
  `__yabu__(:models)` entry), or that whole models table, which a model
  with nested models needs to write and read them, or `%{models: models,
  types: types}` with the image's deftype table (`__yabu__(:types)`)
  too, which a field holding a deftype's value (or a `Result`) needs.
  Each call first makes
  sure of the table (`ensure/3`, cached), then:

  - `insert/4` mints a v4 Uuid as the row's id (any `"id"` the row has is
    overwritten) and appends the row (its `_seq` past every one the table
    ever issued: `Kinoko.Data.Schema.next_seq/1`);
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

  - `"unavailable"`: the write lock or the file is busy past
    `busy_timeout` (`reason: :busy`, "the store is busy; try again": safe
    to retry; SQLite's busy and locked codes, recognized by their fixed
    text), or
    the repo is gone, closed or crashed (`reason: :down`, "the store is
    unavailable": retrying does not help).
  - `"store"`: a constraint failed, a value cannot be stored, or a stored
    value cannot be read as the reader's type. Never a wrong value. A
    value or row the codec refuses is named (`Model.field`); anything
    SQLite itself refuses is "the store rejected the operation".

  SQLite's and the pool's own messages are logged, never returned.
  - `"too-many-rows"`, `"not-found"`: as above.

  `open/2` alone answers `{:error, :bad_name}` for a deployment name that
  is not one (`Kinoko.Universe.Registry.valid_name?/1`).
  """

  require Logger

  alias Kinoko.Data.{Cache, Codec, Lock, LockError, Opener, Repo, Schema}

  @max_rows 10_000

  @busy "the store is busy; try again"
  @down "the store is unavailable"
  @rejected "the store rejected the operation"

  @type repo :: pid()
  @type error :: %{code: String.t(), message: String.t()}
  @type sig ::
          [{String.t(), term(), term()}]
          | %{String.t() => list()}
          | %{models: %{String.t() => list()}, types: map()}

  @doc "The most rows `list/4` returns."
  @spec max_rows() :: pos_integer()
  def max_rows, do: @max_rows

  # ---------- files ----------

  @doc """
  The file of `deployment`. Options: `dir:` (default: the `:dir` of the
  `:kinoko, Kinoko.Data` application env when set, which tests use, else
  `Kinoko.Repo`'s directory).
  """
  @spec path(String.t(), keyword()) :: String.t()
  def path(deployment, opts \\ []) do
    dir = Keyword.get_lazy(opts, :dir, &default_dir/0)
    Path.join([dir, "data", deployment <> ".db"])
  end

  defp default_dir do
    Application.get_env(:kinoko, __MODULE__, [])[:dir] ||
      Kinoko.Release.data_dir(Kinoko.Repo)
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
      with {:ok, _layout, _tables} <- layout(repo, model, sig), do: :ok
    end)
  end

  # ---------- rows ----------

  @doc "Inserts `row`, with a fresh v4 id: `{:ok, id}`."
  @spec insert(repo(), String.t(), sig(), term()) ::
          {:ok, {:uuid, String.t()}} | {:error, error()}
  def insert(repo, model, sig, row) do
    write(repo, fn ->
      with {:ok, layout, tables} <- layout(repo, model, sig),
           {:ok, cells} <- encode(model, layout, row, tables) do
        id = Ecto.UUID.generate()
        t = Schema.quote_name(layout.table)
        cols = Enum.map_join(cells, "", fn {col, _} -> ", " <> Schema.quote_name(col) end)
        marks = String.duplicate(", ?", length(cells))

        {:ok, _} =
          transaction(fn ->
            Repo.query!(
              "INSERT INTO #{t} (id, _seq#{cols}) VALUES (?, ?#{marks})",
              [id, Schema.next_seq(layout.table) | Enum.map(cells, &elem(&1, 1))]
            )
          end)

        {:ok, {:uuid, id}}
      end
    end)
  end

  @doc """
  Every row, in insertion order. Above `max_rows/0` (or `cap:`) rows,
  `"too-many-rows"`. Options: `order: :desc` for newest first, and
  `limit: n` for at most the first `n` rows in that order (never
  `"too-many-rows"`).
  """
  @spec list(repo(), String.t(), sig(), keyword()) :: {:ok, [term()]} | {:error, error()}
  def list(repo, model, sig, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    cap = Keyword.get(opts, :cap, @max_rows)
    dir = if Keyword.get(opts, :order, :asc) == :desc, do: " DESC", else: ""

    run(repo, fn ->
      with {:ok, layout, tables} <- layout(repo, model, sig) do
        result =
          Repo.query!("#{select(layout)} ORDER BY _seq#{dir} LIMIT ?", [limit || cap + 1])

        if limit == nil and length(result.rows) > cap do
          error(
            "too-many-rows",
            "#{model} has more than #{cap} rows, more than a list reads at once"
          )
        else
          decode_all(model, layout, result, tables)
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
           {:ok, layout, tables} <- layout(repo, model, sig) do
        fetch(model, layout, text, tables)
      end
    end)
  end

  @doc "Replaces the row with `id` by `row` (its id kept): `{:ok, id}`; `\"not-found\"` if none."
  @spec update(repo(), String.t(), sig(), {:uuid, String.t()}, term()) ::
          {:ok, {:uuid, String.t()}} | {:error, error()}
  def update(repo, model, sig, id, row) do
    write(repo, fn ->
      with {:ok, text} <- id_text(id),
           {:ok, layout, tables} <- layout(repo, model, sig),
           {:ok, cells} <- encode(model, layout, row, tables) do
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
    write(repo, fn ->
      with {:ok, text} <- id_text(id),
           {:ok, layout, tables} <- layout(repo, model, sig) do
        transaction(fn ->
          case fetch(model, layout, text, tables) do
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

  A schema sync done inside the transaction is cached only once it
  commits (a rollback would undo it): until then later calls in the
  transaction reuse it, and after a rollback the next call syncs again.
  A `transaction/2` inside another joins it.
  """
  @spec transaction(repo(), (-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(repo, fun) do
    write(repo, fn ->
      if Repo.in_transaction?() do
        transaction(fun)
      else
        Cache.defer_begin()

        try do
          with {:ok, _} = result <- transaction(fun) do
            Cache.defer_publish()
            result
          end
        after
          Cache.defer_end()
        end
      end
    end)
  end

  @doc "Rolls back the transaction `transaction/2` is running, which answers `{:error, value}`."
  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback(value)

  defp transaction(fun), do: Repo.transaction(fun)

  # ---------- internals ----------

  # `run/2` under the deployment's write lock, taken before any
  # connection is checked out (`Kinoko.Data.Lock`).
  defp write(repo, fun), do: run(repo, fn -> Lock.with_lock(repo, fun) end)

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

        e in LockError ->
          if e.reason == :busy do
            Logger.info("Kinoko.Data: busy: #{Exception.message(e)}")
            {:error, %{code: "unavailable", reason: :busy, message: @busy}}
          else
            down(e)
          end

        e in DBConnection.ConnectionError ->
          down(e)

        # Ecto's lookup of a repo pid that died since the liveness check.
        e in RuntimeError ->
          if String.starts_with?(e.message, "could not lookup Ecto repo"),
            do: down(e),
            else: reraise(e, __STACKTRACE__)
      catch
        :exit, reason -> down({:exit, reason})
      after
        Repo.put_dynamic_repo(previous)
      end
    else
      down(:closed)
    end
  end

  # SQLite's and the pool's own words (table and column names, file
  # states, pids) never leave here: they are logged, and the caller gets
  # one generic message per class.
  defp sql_error(%Exqlite.Error{message: message} = e) do
    case busy_code(message) do
      nil ->
        Logger.error("Kinoko.Data: SQLite refused: #{Exception.message(e)}")
        %{code: "store", message: @rejected}

      code ->
        Logger.info("Kinoko.Data: busy (#{code}): #{Exception.message(e)}")
        %{code: "unavailable", reason: :busy, message: @busy}
    end
  end

  # The busy and locked result codes, by the error text SQLite fixes for
  # each (`sqlite3_errstr`): Exqlite (0.42) hands over `sqlite3_errmsg`'s
  # text, not the code, and for these codes that text is the fixed one.
  # Matched whole, never as a substring, so no table, column or
  # constraint name can pass for one. "Database is busy" is Exqlite's own
  # (a connection checked out twice, or a busy step).
  @busy_codes %{
    "database is locked" => "SQLITE_BUSY",
    "database table is locked" => "SQLITE_LOCKED",
    "Database is busy" => "exqlite busy"
  }

  defp busy_code(message) when is_binary(message) do
    cond do
      code = Map.get(@busy_codes, message) -> code
      String.starts_with?(message, "database schema is locked: ") -> "SQLITE_LOCKED"
      true -> nil
    end
  end

  defp busy_code(_message), do: nil

  defp down(:closed) do
    Logger.warning("Kinoko.Data: a call on a closed store")
    {:error, %{code: "unavailable", reason: :down, message: @down}}
  end

  defp down(detail) do
    Logger.error("Kinoko.Data: the store is down: #{inspect(detail, limit: 20)}")
    {:error, %{code: "unavailable", reason: :down, message: @down}}
  end

  defp error(code, message), do: {:error, %{code: code, message: message}}

  defp store_error(message), do: error("store", message)

  defp layout(_repo, model, _sig) when not is_binary(model),
    do:
      store_error(
        "this store operation's model never settled (an expression evaluated alone), " <>
          "so it does not run: give the expression a type that names the model"
      )

  defp layout(repo, model, sig) do
    tables =
      if is_list(sig),
        do: %{models: %{model => sig}, types: %{}},
        else: Codec.tables(sig)

    case Map.fetch(tables.models, model) do
      {:ok, fields} when is_list(fields) ->
        case Schema.layout(repo, model, fields) do
          {:ok, layout} -> {:ok, layout, tables}
          {:error, why} -> store_error(why)
        end

      _ ->
        store_error("#{model} is not a model of the given signatures")
    end
  end

  defp encode(model, layout, row, tables) do
    case Codec.encode_row(model, layout.columns, row, tables) do
      {:ok, cells} -> {:ok, cells}
      {:error, why} -> store_error(why)
    end
  end

  defp select(layout) do
    cols =
      Enum.map_join(layout.columns, "", fn {_, _, _, col} -> ", " <> Schema.quote_name(col) end)

    "SELECT id#{cols} FROM #{Schema.quote_name(layout.table)}"
  end

  defp fetch(model, layout, text, tables) do
    case Repo.query!("#{select(layout)} WHERE id = ?", [text]) do
      %{rows: []} -> {:ok, nil}
      result -> with {:ok, [row]} <- decode_all(model, layout, result, tables), do: {:ok, row}
    end
  end

  defp decode_all(model, layout, %{columns: names, rows: rows}, tables) do
    Enum.reduce_while(rows, {:ok, []}, fn cells, {:ok, acc} ->
      case Codec.decode_row(model, layout.columns, Map.new(Enum.zip(names, cells)), tables) do
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
