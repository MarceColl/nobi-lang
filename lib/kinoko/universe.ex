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

  `eval/3`, `call/4`, `test/3`, `apply/4` and `routes/1` also return
  `{:error, %{code: "degraded", message: m}}` while the universe is
  degraded (`health/1`), `m` naming the declarations that fail.

  The caller never crashes on any of them.

  ## Pinned views

  `at/2` gives a `Kinoko.Universe.At`, the universe as of one commit.
  `eval/3`, `call/4`, `test/3`, `apply/4`, `apps/1` and `routes/1` take
  one in place of the universe's name and answer with that commit's code,
  whatever promotes later. `subscribe/1` hears of each new commit.

  ## Degraded

  A universe whose committed code no longer typechecks when it boots (the
  checker changed under stored code) is not refused: it opens **degraded**
  (`Kinoko.Lang.restore/3`). Its committed code is kept exactly as stored
  and `health/1` says which declarations fail and why. `stage/4`,
  `unstage/2`, `staged/1`, `read/2`, `symbols/1` and `history/1` work as
  ever; a patch promotes only when the whole image typechecks with it, and
  the first that does makes the universe healthy again. Until then its code
  cannot run: `eval/3`, `call/4` and `test/3` answer `"degraded"`.

  Only type errors degrade. A declaration missing from the CAS or CAS text
  that does not parse is corrupt storage: the boot refuses (`"internal"`).

  ## Where the work happens

  `stage/4` parses, canonicalizes and hashes in the caller, writes the
  declarations to `Kinoko.Cas`, and only then calls the CodeDb, which checks,
  promotes and persists. A patch that does not parse never reaches the
  CodeDb as a stage: it drops what its id staged before (`{:unstage, id}`)
  and returns `{:staged, [parse reason]}`. `eval/3`, `call/4` and `test/3`
  run in the caller through `Kinoko.Exec`, so a long evaluation never
  blocks the universe. They first ask the CodeDb for its image's hash and
  signatures only (`:image_key`), and take the whole committed code
  (`:snapshot`) only when no image of that hash is loaded yet
  (`Kinoko.Exec.loaded/1`). `apply/4`, `routes/1` and `at/2` (which
  replays history and reads the CAS) run in the caller the same way.

  A promotion is announced by the CodeDb itself, after it is stored, on
  `Kinoko.PubSub` topic `"universe:<name>"` (`subscribe/1`).
  """

  alias Kinoko.{Cas, CodeDb, Exec, Lang}
  alias Kinoko.PersistentElmGenServer, as: Server
  alias Kinoko.Universe.{At, AtCache, Current, Registry}

  @read_timeout 5_000

  @type name :: String.t()
  @type reason :: Lang.reason()
  @type error ::
          {:error, :bad_name | :no_such_universe}
          | {:error, %{code: String.t(), message: String.t()}}

  @doc """
  Every universe, by name: `[%{name, parent, forked_at_commit, created_at}]`,
  or `{:error, %{code: "unavailable", ...}}` when the database cannot be read.
  """
  @spec list() :: [map()] | error
  def list do
    Registry.list()
  rescue
    e -> {:error, unavailable("the universes could not be listed: " <> Exception.message(e))}
  end

  @doc """
  Creates an empty universe: `:ok | {:error, :exists | :bad_name}`, or
  `{:error, %{code: "unavailable", ...}}` when the database cannot be written
  (whether it was created is then unknown: create it again).
  """
  @spec create(name) :: :ok | {:error, :exists | :bad_name} | error
  def create(name) do
    Registry.create(name)
  rescue
    e -> {:error, unavailable("universe #{name} could not be created: " <> Exception.message(e))}
  end

  @doc """
  `:ok`, or `{:degraded, [reason]}` while the universe's committed code does
  not typecheck (see "Degraded"; each reason names a failing declaration).
  """
  @spec health(name) :: :ok | {:degraded, [reason]} | error
  def health(universe), do: read_request(universe, :health)

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
        with :ok <- put_texts(texts),
             do: request(universe, {:stage, universe, id, entries}, :infinity)

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
    case request(universe, {:unstage, universe, id}, :infinity) do
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
      case request(universe, {:unstage, universe, id}, :infinity) do
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
  @spec eval(name | At.t() | Current.t(), String.t(), keyword()) :: {:ok, term(), term()} | error
  def eval(universe, expr_source, opts \\ []) do
    with {:ok, target} <- target(universe) do
      if is_binary(expr_source),
        do: staged_hint(universe, Exec.eval(target, expr_source, opts)),
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
  @spec call(name | At.t() | Current.t(), String.t(), [term()], keyword()) ::
          {:ok, term(), term()} | error
  def call(universe, symbol, args, opts \\ []) do
    with {:ok, target} <- target(universe),
         {:ok, value} <- staged_hint(universe, Exec.call(run_on(target), symbol, args, opts)) do
      {:ok, value, return_type(target, symbol)}
    end
  end

  defp return_type(%{signatures: sigs}, symbol) do
    case sigs do
      %{^symbol => {:def, _params, ret, _names}} -> ret
      _ -> nil
    end
  end

  @doc "Runs deftest `symbol` of the current commit, in the caller: `:ok | {:error, %{code, message, ...}}`."
  @spec test(name | At.t() | Current.t(), String.t(), keyword()) :: :ok | error
  def test(universe, symbol, opts \\ []) do
    with {:ok, target} <- target(universe),
         do: staged_hint(universe, Exec.test(run_on(target), symbol, opts))
  end

  # What Exec runs against: the loaded image and the signatures (the fast
  # path: only the hash and the signatures leave the CodeDb), else the
  # whole snapshot, whose image Exec then loads. A pinned view's image is
  # found by its hash, else rebuilt from history.
  defp target(%At{hash: hash, signatures: sigs} = at) do
    case Exec.loaded(hash) do
      {:ok, image} -> {:ok, %{image: image, signatures: sigs}}
      :error -> snapshot_at(at)
    end
  end

  defp target(%Current{universe: universe, hash: hash, signatures: sigs}) do
    case Exec.loaded(hash) do
      {:ok, image} -> {:ok, %{image: image, signatures: sigs}}
      :error -> target(universe)
    end
  end

  defp target(universe) do
    case read_request(universe, :image_key) do
      {:ok, hash, sigs} ->
        case Exec.loaded(hash) do
          {:ok, image} -> {:ok, %{image: image, signatures: sigs}}
          :error -> snapshot(universe)
        end

      other ->
        runnable(universe, other)
    end
  end

  defp snapshot(universe) do
    case read_request(universe, :snapshot) do
      {:ok, snapshot} -> {:ok, snapshot}
      other -> runnable(universe, other)
    end
  end

  defp runnable(universe, {:degraded, reasons}), do: {:error, degraded(universe, reasons)}
  defp runnable(_universe, {:error, _} = error), do: error

  defp run_on(%{image: image}), do: image
  defp run_on(snapshot), do: snapshot

  defp degraded(universe, reasons) do
    %{
      code: "degraded",
      message:
        "universe #{universe} is degraded: its committed code no longer typechecks " <>
          "(failing: #{failing(reasons)}), so nothing runs until a patch that fixes it " <>
          "promotes. health shows why.",
      reasons: reasons
    }
  end

  defp degraded_at(universe, commit, reasons) do
    %{
      code: "degraded",
      message:
        "commit #{commit} of universe #{universe} no longer typechecks " <>
          "(failing: #{failing(reasons)}), so it cannot run",
      reasons: reasons
    }
  end

  defp failing(reasons) do
    reasons
    |> Enum.map(&Map.get(&1, :name))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map_join(", ", &"`#{&1}`")
  end

  # An error naming a symbol that only a staged patch defines says so: the
  # code runs against committed code, where it does not exist yet.
  defp staged_hint(universe, {:error, %{code: code, message: message} = error} = result)
       when code in ["unbound", "runtime"] and is_binary(message) and is_binary(universe) do
    case read_request(universe, :definers) do
      definers when is_map(definers) and map_size(definers) > 0 ->
        hint = &hinted(&1, definers)
        error = %{error | message: hint.(message)}

        error =
          case error do
            %{reasons: reasons} when is_list(reasons) ->
              %{error | reasons: Enum.map(reasons, &Map.update!(&1, :message, hint))}

            _ ->
              error
          end

        {:error, error}

      _ ->
        result
    end
  end

  defp staged_hint(%Current{universe: universe}, result), do: staged_hint(universe, result)
  defp staged_hint(_universe_or_at, result), do: result

  defp hinted(message, definers) do
    staged =
      for {symbol, ids} <- Enum.sort(definers),
          String.contains?(message, "`#{symbol}`"),
          do: {symbol, "staged under #{Enum.map_join(ids, ", ", &"`#{&1}`")}, not promoted"}

    case staged do
      [] ->
        message

      [{_symbol, note}] ->
        "#{message} (#{note})"

      many ->
        "#{message} (" <> Enum.map_join(many, "; ", fn {s, note} -> "`#{s}` #{note}" end) <> ")"
    end
  end

  @doc """
  The universe's committed image as it is now: `{:ok, current}`, a
  `Kinoko.Universe.Current` that `call/4`, `apply/4`, `eval/3`, `test/3`
  and `routes/1` take in place of the name. Every call on it runs that
  image, with no further CodeDb round trip: a host doing several calls in
  a row (a route lookup, `init`, `view`) resolves the universe once and
  runs them all on one commit's code. `{:error, ...}` as `call/4` (a
  degraded universe answers `"degraded"`).
  """
  @spec current(name) :: {:ok, Current.t()} | error
  def current(universe) when is_binary(universe) do
    case read_request(universe, :image_key) do
      {:ok, hash, sigs} -> {:ok, %Current{universe: universe, hash: hash, signatures: sigs}}
      other -> runnable(universe, other)
    end
  end

  @doc """
  Applies `fun`, a Yabu function value this universe's code made (a
  closure, a def taken as a value, a constructor; e.g. a view's handler or
  an effect's callback), to `args`, in the caller through `Kinoko.Exec.apply/4`
  against the current commit (or a pinned view, `at/2`): `{:ok, value}` or
  `{:error, %{code, message}}`. Bounded as `call/4` is (`opts` are its
  limits). A value that is no function or takes another number of
  arguments is code `"runtime"`; a closure whose image has been unloaded
  is code `"unloaded"`. A closure runs the code of the image it came from,
  whichever commit `universe_or_at` is now. `opts` has no default: an
  `apply/3` would clash with `Kernel.apply/3` inside this module.
  """
  @spec apply(name | At.t() | Current.t(), term(), [term()], keyword()) :: {:ok, term()} | error
  def apply(universe_or_at, fun, args, opts) do
    with {:ok, target} <- target(universe_or_at),
         do: Exec.apply(run_on(target), fun, args, opts)
  end

  @doc """
  The committed `defapp`s, sorted: `[app_symbol]`. Read from the symbols,
  so a degraded universe lists its apps too.
  """
  @spec apps(name | At.t()) :: [String.t()] | error
  def apps(%At{signatures: sigs}),
    do: for({symbol, :app} <- Enum.sort(sigs), do: symbol)

  def apps(universe) do
    with symbols when is_list(symbols) <- symbols(universe),
         do: for(%{symbol: symbol, signature: "app"} <- symbols, do: symbol)
  end

  @doc """
  The committed route tables, `%{routes_name => [%{segments, app, params}]}`
  (`Kinoko.Lang.Codegen`; match a path with `Kinoko.Lang.Routes`), of the
  current commit or a pinned view. Read from the image, so a degraded
  universe answers `"degraded"`.
  """
  @spec routes(name | At.t() | Current.t()) :: map() | error
  def routes(universe_or_at) do
    with {:ok, target} <- target(universe_or_at),
         {:ok, routes} <- Exec.routes(run_on(target)),
         do: routes
  end

  @doc """
  Subscribes the caller to the universe's commits: after each write that
  adds commits, once it is stored, it receives
  `{:committed, universe, %{commit: n, image_hash: hash}}`, `commit` the
  newest (1-based into `history/1`; one write can add several) and `hash`
  its image's. Staging that promotes nothing sends nothing. `:ok`.
  """
  @spec subscribe(name) :: :ok | error
  def subscribe(universe) do
    with :ok <- check(universe),
         do: Phoenix.PubSub.subscribe(Kinoko.PubSub, CodeDb.topic(universe))
  end

  @doc """
  The `Kinoko.PubSub` topic `subscribe/1` subscribes to, for a host that
  subscribes through its own effect (`Kinoko.Elm.Effect.subscribe/3`).
  Pure: the universe is not checked.
  """
  @spec topic(name) :: String.t()
  def topic(universe) when is_binary(universe), do: CodeDb.topic(universe)

  @doc """
  The newest commit's number (`length(history(universe))`, 0 for none), or
  an error.
  """
  @spec head(name) :: non_neg_integer() | error
  def head(universe) do
    case history(universe) do
      history when is_list(history) -> length(history)
      error -> error
    end
  end

  @doc """
  A pinned view of the universe as of commit `commit` (1-based into
  `history/1`): `{:ok, at}`, an opaque `Kinoko.Universe.At` that `call/4`,
  `apply/4`, `eval/3`, `test/3`, `apps/1` and `routes/1` take in place of
  the universe's name. It answers with that commit's code whatever
  promotes later.

  Built in the caller, never in the CodeDb: the history is replayed up to
  `commit`, its declarations fetched from `Kinoko.Cas` and checked again
  (`Kinoko.Lang.restore/3`), and the image loaded. The history is read on
  every call; views are cached (`Kinoko.Universe.AtCache`, ETS) by
  `{universe, commit}` and a fingerprint of the history up to `commit`, so
  a name reused with another history is rebuilt, never served stale.
  Images are cached by hash (`Kinoko.Exec`); nothing is evicted. A
  degraded universe opens its older commits that still typecheck.

  `{:error, %{code: "no_such_commit", message: m}}` when `commit` is not
  one of the history's; `{:error, %{code: "degraded", ...}}` when that
  commit's code no longer typechecks.
  """
  @spec at(name, pos_integer()) :: {:ok, At.t()} | error
  def at(universe, commit) do
    with {:ok, rounds} <- rounds(universe, commit) do
      fingerprint = AtCache.fingerprint(rounds)

      case AtCache.get(universe, commit, fingerprint) do
        {:ok, at} ->
          {:ok, at}

        :error ->
          with {:ok, snapshot} <- restore_at(universe, commit, rounds),
               {:ok, image} <- Exec.load(snapshot) do
            at = %At{
              universe: universe,
              commit: commit,
              fingerprint: fingerprint,
              hash: image.hash,
              signatures: snapshot.signatures
            }

            :ok = AtCache.put(universe, commit, fingerprint, at)
            {:ok, at}
          end
      end
    end
  end

  # The history's first `commit` rounds, read from the CodeDb every time:
  # the cache is trusted only for the history it was built from.
  defp rounds(universe, commit) do
    with history when is_list(history) <- read_request(universe, :history),
         :ok <- in_history(universe, commit, length(history)),
         do: {:ok, Enum.take(history, commit)}
  end

  # A pinned view's snapshot again (its image was unloaded), only while the
  # universe's history still starts with the rounds the view was made from.
  defp snapshot_at(%At{universe: universe, commit: commit, fingerprint: fingerprint}) do
    with {:ok, rounds} <- rounds(universe, commit) do
      if AtCache.fingerprint(rounds) == fingerprint,
        do: restore_at(universe, commit, rounds),
        else:
          {:error,
           %{
             code: "no_such_commit",
             message:
               "universe #{universe}'s history changed under commit #{commit}: open it again"
           }}
    end
  end

  # Commit `commit`'s snapshot, rebuilt from its rounds in the caller.
  defp restore_at(universe, commit, rounds) do
    case CodeDb.restore(rounds, []) do
      {:ok, u} -> {:ok, Lang.snapshot(u)}
      {:degraded, _u, reasons} -> {:error, degraded_at(universe, commit, reasons)}
      {:error, reasons} -> {:error, internal(Enum.map_join(reasons, "; ", & &1.message))}
    end
  rescue
    e ->
      if db_outage?(e),
        do:
          {:error,
           unavailable("commit #{commit} of #{universe} could not be read: " <> describe(e))},
        else:
          {:error, internal("commit #{commit} of #{universe} does not restore: " <> describe(e))}
  end

  defp in_history(_universe, commit, n) when is_integer(commit) and commit in 1..n//1, do: :ok

  defp in_history(universe, commit, n) do
    {:error,
     %{
       code: "no_such_commit",
       message:
         "universe #{universe} has no commit #{inspect(commit, limit: 5)}: " <>
           if(n == 0, do: "it has no commits yet", else: "its commits are 1 to #{n}")
     }}
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

  @db_errors [DBConnection.ConnectionError, DBConnection.OwnershipError, Exqlite.Error]

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
