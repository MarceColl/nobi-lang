defmodule Kinoko.Universe do
  @moduledoc """
  The system's only interface to universes. Every function takes the
  universe's name first (`"main"` exists from boot; others are `create/1`d).
  Callers never see processes: each running universe is a `Kinoko.CodeDb`,
  started on demand here and reached only from here.

  ## Errors

  Besides each function's own results, every function that takes a
  universe can return:

    * `{:error, :bad_name}`: not a universe name
      (`~r/^[a-z0-9][a-z0-9_-]{0,62}$/`);
    * `{:error, :no_such_universe}`: no universe has that name;
    * `{:error, %{code: "internal", message: m}}`: the universe failed to
      boot (for example a declaration missing from the CAS; `m` names its
      CID), or its CodeDb crashed while answering;
    * `{:error, %{code: "unavailable", message: m}}`: the database or the
      CodeDb could not be reached (the database failed while the universe
      booted or answered, the CodeDb went away mid-call, or a read timed
      out). A write's outcome is then unknown: restage the same id, which is
      idempotent.

  The caller never crashes on any of them.

  ## Where the work happens

  `stage/4` parses, canonicalizes and hashes in the caller, writes the
  declarations to `Kinoko.Cas`, and only then calls the CodeDb, which checks,
  promotes and persists. A patch that does not parse never reaches the
  CodeDb as a stage: it drops what its id staged before (`{:unstage, id}`)
  and returns `{:staged, [parse reason]}`. `eval/3`, `call/4` and `test/3`
  take a snapshot from the CodeDb and run in the caller through
  `Kinoko.Exec`, so a long evaluation never blocks the universe.
  """

  alias Kinoko.{Cas, CodeDb, Exec, Lang}
  alias Kinoko.PersistentElmGenServer, as: Server
  alias Kinoko.Universe.Registry

  @read_timeout 5_000

  @type name :: String.t()
  @type reason :: Lang.reason()
  @type error ::
          {:error, :bad_name | :no_such_universe}
          | {:error, %{code: String.t(), message: String.t()}}

  @doc "Every universe, by name: `[%{name, parent, forked_at_commit, created_at}]`."
  @spec list() :: [map()]
  def list, do: Registry.list()

  @doc "Creates an empty universe: `:ok | {:error, :exists | :bad_name}`."
  @spec create(name) :: :ok | {:error, :exists | :bad_name}
  def create(name), do: Registry.create(name)

  @doc """
  Stages `source` under patch `id` (`remove: [symbol]` also stages
  removals), then promotes whatever can: `{:promoted, [id]}`, or
  `{:staged, [reason]}` with why the patch cannot promote now. Restaging an
  id replaces its patch. Source that does not parse drops what `id` staged
  before and returns `{:staged, [%{code: "parse", ...}]}`.
  """
  @spec stage(name, String.t(), String.t(), keyword()) ::
          {:promoted, [String.t()]} | {:staged, [reason]} | error
  def stage(universe, id, source, opts \\ []) do
    with :ok <- check(universe) do
      if is_binary(id), do: prepare_and_stage(universe, id, source, opts), else: bad_id(id)
    end
  end

  defp prepare_and_stage(universe, id, source, opts) do
    case Lang.prepare(source, opts) do
      {:ok, entries, texts} ->
        with :ok <- put_texts(texts), do: request(universe, {:stage, id, entries}, :infinity)

      # As `Kinoko.Lang.stage/4`: source that does not parse supersedes what
      # `id` staged; input refused for its type does not.
      {:error, [%{code: "parse"}] = reasons} when is_binary(source) ->
        with {:ok, _} <- unstage_quietly(universe, id), do: {:staged, reasons}

      {:error, reasons} ->
        {:staged, reasons}
    end
  end

  defp bad_id(id),
    do:
      {:staged,
       [%{name: nil, code: "bad-id", message: "a patch id is a string, not #{inspect(id)}"}]}

  defp unstage_quietly(universe, id) do
    case request(universe, {:unstage, id}, :infinity) do
      {:error, %{} = error} -> {:error, Map.take(error, [:code, :message])}
      other -> {:ok, other}
    end
  end

  # The CAS is written before the CodeDb references the CIDs, so a crash in
  # between leaves at worst unreferenced rows.
  defp put_texts(texts) do
    Cas.put(texts)
  rescue
    e ->
      {:error, %{code: "unavailable", message: "the CAS write failed: " <> Exception.message(e)}}
  end

  @doc "Drops patch `id`: `:ok`, or `:not_found` when nothing is staged under it."
  @spec unstage(name, String.t()) :: :ok | :not_found | error
  def unstage(universe, id) do
    with :ok <- check(universe) do
      case request(universe, {:unstage, id}, :infinity) do
        {:error, %{code: _, message: message, name: _}} ->
          {:error, %{code: "internal", message: message}}

        other ->
          other
      end
    end
  end

  @doc """
  The staged patches, in the order they were last staged:
  `[%{id, source, removes, reasons}]`, `source` the canonical text of the
  declarations the patch defines and `reasons` why it cannot promote now.
  """
  @spec staged(name) :: [map()] | error
  def staged(universe), do: read_request(universe, :staged)

  @doc "Canonical text of `symbol` (committed, else staged): `{:ok, text} | :error`."
  @spec read(name, String.t()) :: {:ok, String.t()} | :error | error
  def read(universe, symbol), do: read_request(universe, {:read, symbol})

  @doc "Committed symbols, sorted: `[%{symbol, cid, signature}]`."
  @spec symbols(name) :: [map()] | error
  def symbols(universe), do: read_request(universe, :symbols)

  @doc "Every promoted round, oldest first: `[%{ids: [id], entries: [{:live, symbol, cid} | {:gone, symbol}]}]`."
  @spec history(name) :: [map()] | error
  def history(universe), do: read_request(universe, :history)

  @doc """
  Checks `expr_source` against the current commit and evaluates it, in the
  caller: `{:ok, value, type}` or `{:error, %{code, message}}`
  (`Kinoko.Exec.eval/3`; `opts` are its limits, e.g. `timeout:`).
  """
  @spec eval(name, String.t(), keyword()) :: {:ok, term(), term()} | error
  def eval(universe, expr_source, opts \\ []) do
    with {:ok, snapshot} <- snapshot(universe) do
      if is_binary(expr_source),
        do: Exec.eval(snapshot, expr_source, opts),
        else:
          {:error,
           %{code: "parse", message: "an expression is a string, not #{inspect(expr_source)}"}}
    end
  end

  @doc """
  Calls def `symbol` of the current commit with `args`, in the caller:
  `{:ok, value, type}` (`type` the def's declared return type, as `eval/3`
  gives one) or `{:error, %{code, message}}`.
  """
  @spec call(name, String.t(), [term()], keyword()) :: {:ok, term(), term()} | error
  def call(universe, symbol, args, opts \\ []) do
    with {:ok, snapshot} <- snapshot(universe),
         {:ok, value} <- Exec.call(snapshot, symbol, args, opts) do
      {:ok, value, return_type(snapshot, symbol)}
    end
  end

  defp return_type(%{signatures: sigs}, symbol) do
    case sigs do
      %{^symbol => {:def, _params, ret}} -> ret
      _ -> nil
    end
  end

  @doc "Runs deftest `symbol` of the current commit, in the caller: `:ok | {:error, %{code, message, ...}}`."
  @spec test(name, String.t(), keyword()) :: :ok | error
  def test(universe, symbol, opts \\ []) do
    with {:ok, snapshot} <- snapshot(universe), do: Exec.test(snapshot, symbol, opts)
  end

  defp snapshot(universe) do
    case read_request(universe, :snapshot) do
      {:error, _} = error -> error
      snapshot -> {:ok, snapshot}
    end
  end

  ## Routing

  defp read_request(universe, msg) do
    with :ok <- check(universe), do: request(universe, msg, @read_timeout)
  end

  # Name validity and existence. A running CodeDb proves existence, so the
  # table is consulted only when none is.
  defp check(name) do
    cond do
      not Registry.valid_name?(name) -> {:error, :bad_name}
      Server.whereis(CodeDb.key(name)) -> :ok
      Registry.exists?(name) -> :ok
      # The boot task may have failed or been skipped: create main now.
      name == "main" -> Registry.ensure_main()
      true -> {:error, :no_such_universe}
    end
  rescue
    e ->
      {:error, unavailable("the universe registry could not be read: " <> Exception.message(e))}
  end

  # Calls the universe's CodeDb, starting it first when none runs. A call
  # that finds the process gone before it was received is retried once
  # (the request never ran); every other exit becomes an error.
  defp request(name, msg, timeout, retries \\ 1) do
    with {:ok, pid} <- ensure_started(name) do
      try do
        GenServer.call(pid, msg, timeout)
      catch
        :exit, reason ->
          if retries > 0 and noproc?(reason),
            do: request(name, msg, timeout, retries - 1),
            else: {:error, exit_error(name, reason)}
      end
    end
  end

  defp ensure_started(name) do
    case Server.whereis(CodeDb.key(name)) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case Server.start(CodeDb, nil, key: CodeDb.key(name)) do
          {:ok, pid} -> {:ok, pid}
          # Another start won the race for the key.
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, boot_error(name, reason)}
        end
    end
  catch
    :exit, reason ->
      {:error, unavailable("universe #{name} could not be started: " <> describe(reason))}
  end

  # A boot that failed because the database did not answer is an outage;
  # any other failure is the stored universe's (a CAS row missing, text
  # that does not parse).
  defp boot_error(name, reason) do
    if db_outage?(reason),
      do:
        unavailable("universe #{name} could not be read from the database: " <> describe(reason)),
      else: internal("universe #{name} failed to boot: " <> describe(reason))
  end

  @db_errors [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error]

  defp db_outage?({%{__struct__: module}, stack}) when is_list(stack), do: module in @db_errors
  defp db_outage?(%{__struct__: module}), do: module in @db_errors
  defp db_outage?(_), do: false

  defp noproc?({:noproc, _}), do: true
  defp noproc?({{:nodedown, _}, _}), do: true
  defp noproc?(_), do: false

  defp exit_error(name, {:timeout, _}),
    do: unavailable("universe #{name} did not answer in time")

  defp exit_error(name, {reason, _call}) when reason in [:noproc, :normal, :shutdown, :killed],
    do: unavailable("universe #{name} stopped while answering (#{inspect(reason)})")

  defp exit_error(name, {{:shutdown, _}, _call}),
    do: unavailable("universe #{name} stopped while answering")

  defp exit_error(name, {reason, _call}) do
    if db_outage?(reason),
      do: unavailable("universe #{name} lost the database while answering: " <> describe(reason)),
      else: internal("universe #{name} crashed while answering: " <> describe(reason))
  end

  defp exit_error(name, reason),
    do: internal("universe #{name} crashed while answering: " <> describe(reason))

  defp describe({%{__exception__: true} = e, stack}) when is_list(stack), do: Exception.message(e)
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(reason), do: inspect(reason, limit: 20, printable_limit: 500)

  defp internal(message), do: %{code: "internal", message: message}
  defp unavailable(message), do: %{code: "unavailable", message: message}
end
