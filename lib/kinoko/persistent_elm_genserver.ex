defmodule Kinoko.PersistentElmGenServer do
  @moduledoc """
  A `Kinoko.ElmGenServer` whose state survives restarts and crashes.

  Every changed state is appended to Postgres (`Kinoko.Elm.Store`, table
  `elm_states`) under the server's key *before* that step's effects run. A
  server started again under the same key resumes from its last written state.
  `init/1` and `update/2` are the same as in `Kinoko.ElmGenServer`; so are
  `call/3` and `cast/2`, which also take the key in place of a pid.

  ## Example

      iex> defmodule Demo.PersistentCounter do
      ...>   use Kinoko.PersistentElmGenServer
      ...>   alias Kinoko.Elm.Effect, as: Fx
      ...>
      ...>   def init(start), do: {%{count: start}, Fx.none()}
      ...>
      ...>   def update({:call, from, :inc}, s),
      ...>     do: {%{s | count: s.count + 1}, Fx.reply(from, s.count + 1)}
      ...>
      ...>   def update({:call, from, :count}, s), do: {s, Fx.reply(from, s.count)}
      ...> end
      iex> {:ok, pid} = Kinoko.PersistentElmGenServer.start(Demo.PersistentCounter, 0, key: "counter:demo")
      iex> Kinoko.PersistentElmGenServer.call("counter:demo", :inc)
      1
      iex> Kinoko.PersistentElmGenServer.call("counter:demo", :inc)
      2
      iex> GenServer.stop(pid)
      :ok
      iex> {:ok, _pid} = Kinoko.PersistentElmGenServer.start(Demo.PersistentCounter, 0, key: "counter:demo")
      iex> Kinoko.PersistentElmGenServer.call("counter:demo", :count)
      2

  The second start found a stored state, so it skipped `init/1` (and its
  argument) and called `resume/1` with the count of 2. (`GenServer.stop/1`
  stops it for good: `start/3` children restart only after a crash.)

  ## Starting and supervising

  `start/3` starts the server under `Kinoko.Elm.Supervisor`, a
  `DynamicSupervisor` in the application tree. **Run persistent servers there,
  or under a supervisor of your own that is isolated the same way**, not
  directly under a supervisor whose other children matter. A server reads
  Postgres when it boots and writes it on every changed step, so while the
  DB is down it crashes, and its restarts fail, in a loop. Under a supervisor
  with the default intensity (3 restarts in 5 s) that loop takes the
  supervisor down, then its parent, up to the application.
  `Kinoko.Elm.Supervisor` tolerates 1000 restarts a minute; if an outage
  outlasts even that, it dies alone, the root restarts it empty, and its
  servers are gone until something calls `start/3` again.

  `start_link/3` links to the caller, for callers that supervise the server
  themselves. Its generated child spec is
  `{Demo.PersistentCounter, key: "counter:demo", args: 0}` (`id: {module, key}`,
  so one module can run under many keys).

  One live process per key per node, enforced by the `Kinoko.Elm.Registry`
  name: a second start under a running key returns
  `{:error, {:already_started, pid}}` and writes nothing. `whereis/1` finds it.

  A key belongs to one module: every row stores the name of the module that
  wrote it, and a server whose module differs from the stored one refuses to
  boot.

  ## Callbacks

  Besides `init/1` and `update/2`, all optional (`use` provides the defaults):

    * `version/0`, default `1`, stored with every row
    * `migrate(state, from_version)`, see below
    * `resume(state) :: {state, effects}`, called *instead of* `init/1` when a
      stored state exists. Default `{state, []}`. Restart timers here: an
      `Effect.after_ms/2` pending when the old process died died with it.
    * `durable(state) :: term`, the part of the state that is stored. Default:
      the whole state. See below.
    * `encode(durable) :: binary` and `decode(binary) :: state`, see below

  ## Durability

  The guarantee is narrow: **a step's effects never run before its state is
  written**. Not the converse.

    * **Written before effects.** The write is a `Kinoko.Elm.Runtime` `on_step`
      hook, which runs after `init`/`update`/`resume` returns and before any
      effect of that step is performed. A reply or a message is never released
      for a state that was not written. If the write fails (the DB is down,
      `encode` raises), the server crashes, the step's effects are never
      performed, and a restart resumes the last written state.
    * **Effects are at-most-once; the stored state may be ahead of them.** A
      committed row does not mean its effects ran. The process can die between
      the append and the effects; the caller of a `call/3` can be killed while
      the insert runs; a `call/3` can time out while the write still commits.
      A failed or timed-out call therefore means *outcome unknown*, not *did
      not happen*: the state may already include it. Callers that retry must
      make the request idempotent or check the state first.
    * **Only changes are written.** A step whose `durable/1` projection is
      `===` the last one written appends nothing. Otherwise it appends the
      next `seq`, continuing across restarts from the stored one.
    * **Late writes are fenced by `(key, seq)`.** The primary key makes every
      append of a given seq unique. If a dying process still finishes a write
      after its successor booted, one of the two inserts of that seq fails and
      that server crashes; a crashed newcomer restarts and resumes the state
      that won. So there is one live writer per key per node (the Registry),
      and if two nodes ever run the same key (split-brain), the PK turns the
      conflict into crashes, never into one writer silently overwriting the
      other.
    * **In-flight effects are lost.** An HTTP request, task or timer started
      before a crash does not come back to the new process, and messages in
      the mailbox are lost as with any GenServer. Callers retry; `resume/1`
      restarts timers. Durable effects (an intent log with redelivery) are out
      of scope.
    * **Stale pids, refs and funs.** `term_to_binary` stores them, so a state
      holding them (e.g. a list of `from`s waiting for a reply) boots fine, but
      after a restart pids point at processes that may be gone. Sending to them
      is harmless; waiting on them is not. A stored anonymous fun boots fine
      too, but raises `BadFunctionError` when called once the module that
      defined it has been recompiled (any deploy). Clear such fields in
      `resume/1`, or drop them with `durable/1`.

  ## Versions and `migrate/2`

  Every row stores `version/0`. On boot, when the stored version differs from
  the module's, `migrate(state, stored_version)` must return the state in the
  current shape. The default raises, naming both versions (and saying so when
  the stored version is *newer*, i.e. the code was rolled back), so a version
  bump without a migration refuses to boot rather than run on a state it does
  not understand. Any raise in `migrate/2` fails boot with the key, seq and
  versions in the error. A migrated state is always written once (under the
  new version) before any effect runs; if it then fails `encode/1`, boot
  crashes with an error naming the module and key.

  ## Storage cost and pruning

  Each changed step stores the *whole* encoded state: a 5 MB state that
  changes on every message writes 5 MB per message. Keep persistent state
  small, or store less with `durable/1` or `encode/1`. `keep:` on
  `start_link/3` (default 100) bounds the rows: on boot, and after every
  `keep` appends, a process deletes all but the newest `keep` rows of its
  key, so a key that keeps crashing stays bounded too. Pruning is
  maintenance: if it fails, a warning is logged and the step goes on. Rows
  are never updated; `Kinoko.Elm.Store.history/2` reads them back.

  ## Durable projection and custom encoding

  `durable(state)` returns what is stored, so a state can carry volatile
  fields (a cache, a derived index, pids) that never cause a write and never
  reach the table: a step that changes only them appends nothing. `encode/1`
  receives that projection, not the state, and `decode/1` must rebuild a
  *full* state from it, recomputing whatever `durable/1` dropped.

  The default encoding is `:erlang.term_to_binary/1` and
  `:erlang.binary_to_term(binary, [:safe])`. `:safe` never creates atoms from
  stored data, so a binary naming an atom this node does not know (a renamed
  module, a removed tag) refuses to boot with an error naming the key and seq
  rather than leaking atoms.

  The code DB server (piece 3) holds a `Kinoko.Lang` universe: its
  `durable/1` keeps only the universe's `history` (rounds) and `texts`, and
  its `decode/1` rebuilds the universe from them with `Kinoko.Lang.restore/2`,
  which checks the code again on every boot.
  """

  use GenServer

  require Logger

  alias Kinoko.Elm.{Effect, Host, Runtime, Store, Timeline}

  @host "a PersistentElmGenServer"

  @callback init(args :: term()) :: {state :: term(), Effect.effects()}
  @callback update(msg :: term(), state :: term()) :: {state :: term(), Effect.effects()}
  @callback version() :: pos_integer()
  @callback migrate(state :: term(), from_version :: pos_integer()) :: term()
  @callback resume(state :: term()) :: {state :: term(), Effect.effects()}
  @callback durable(state :: term()) :: term()
  @callback encode(durable :: term()) :: binary()
  @callback decode(binary()) :: term()

  defmacro __using__(_opts) do
    quote do
      @behaviour Kinoko.PersistentElmGenServer

      def child_spec(opts) do
        {args, opts} = Keyword.pop(opts, :args)

        %{
          id: {__MODULE__, Keyword.fetch!(opts, :key)},
          start: {Kinoko.PersistentElmGenServer, :start_link, [__MODULE__, args, opts]}
        }
      end

      def version, do: 1

      def migrate(_state, from_version),
        do: Kinoko.PersistentElmGenServer.no_migration!(__MODULE__, from_version)

      def resume(state), do: {state, Kinoko.Elm.Effect.none()}

      def durable(state), do: state

      def encode(durable), do: :erlang.term_to_binary(durable)

      def decode(binary), do: :erlang.binary_to_term(binary, [:safe])

      defoverridable child_spec: 1,
                     version: 0,
                     migrate: 2,
                     resume: 1,
                     durable: 1,
                     encode: 1,
                     decode: 1
    end
  end

  ## Client API

  @doc """
  Starts `module` under `Kinoko.Elm.Supervisor` with `key: key` (a string),
  at most one live process per key on this node. `keep:` (default 100)
  bounds the rows kept per key.

  The child is `:transient`: restarted after a crash, not after a normal
  stop. Returns what `DynamicSupervisor.start_child/2` does, including
  `{:error, {:already_started, pid}}`.
  """
  def start(module, args, opts) do
    validate!(opts)

    DynamicSupervisor.start_child(Kinoko.Elm.Supervisor, %{
      id: {module, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [module, args, opts]},
      restart: :transient
    })
  end

  @doc """
  Starts `module` under `key: key` (a string), linked to the caller, at most
  one live process per key on this node. `keep:` (default 100) bounds the
  rows kept per key. Prefer `start/3` unless the caller supervises the
  server in an isolated supervisor (see the moduledoc).
  """
  def start_link(module, args, opts) do
    {key, keep} = validate!(opts)
    GenServer.start_link(__MODULE__, {module, args, key, keep}, name: via(key))
  end

  @doc "Like `GenServer.call/3`; `server` is a key or a pid."
  def call(server, request, timeout \\ 5000),
    do: GenServer.call(server(server), request, timeout)

  @doc "Like `GenServer.cast/2`; `server` is a key or a pid."
  def cast(server, msg), do: GenServer.cast(server(server), msg)

  @doc "The pid running under `key`, or `nil`."
  def whereis(key) when is_binary(key) do
    # The Registry drops a dead process's entry asynchronously; don't report it.
    case Registry.lookup(Kinoko.Elm.Registry, key) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  def timeline(server), do: Timeline.fetch(server(server))
  def print_timeline(server), do: Timeline.print(server(server))

  @doc false
  def no_migration!(module, from_version) do
    current = module.version()

    if from_version > current do
      raise "#{inspect(module)} found a state stored at version #{from_version}, " <>
              "newer than its own version #{current}: a later release wrote it, " <>
              "so this code was probably rolled back. migrate/2 brings older " <>
              "states forward; deploy the newer code, or implement migrate/2 " <>
              "for version #{from_version} explicitly."
    else
      raise "#{inspect(module)} found a state stored at version #{from_version}, " <>
              "but is at version #{current}. Implement migrate/2 " <>
              "to bring a version #{from_version} state up to date."
    end
  end

  defp validate!(opts) do
    key = Keyword.fetch!(opts, :key)
    keep = Keyword.get(opts, :keep, 100)

    unless is_binary(key), do: raise(ArgumentError, "key must be a string, got: #{inspect(key)}")

    unless is_integer(keep) and keep > 0,
      do: raise(ArgumentError, "keep must be a positive integer")

    {key, keep}
  end

  defp via(key), do: {:via, Registry, {Kinoko.Elm.Registry, key}}

  defp server(key) when is_binary(key), do: via(key)
  defp server(server), do: server

  ## GenServer callbacks

  @impl true
  def init({module, args, key, keep}) do
    {init_msg, init_fun, written} =
      case Store.latest(key) do
        :none ->
          {{:init, args}, fn -> module.init(args) end, %{seq: -1, durable: :none}}

        {:ok, row} ->
          check_module!(module, key, row)
          {state, written} = load!(module, key, row)
          prune(key, keep)
          {{:resume, row.seq}, fn -> module.resume(state) end, written}
      end

    persist = fn state, _seq, acc -> persist(module, key, keep, state, acc) end
    hook = {persist, Map.put(written, :appends, 0)}

    module |> Runtime.init(init_msg, init_fun, on_step: hook) |> Host.init(@host)
  end

  @impl true
  def handle_call(request, from, runtime), do: Host.handle_call(request, from, runtime, @host)

  @impl true
  def handle_cast(msg, runtime), do: Host.handle_cast(msg, runtime, @host)

  @impl true
  def handle_info(msg, runtime), do: Host.handle_info(msg, runtime, @host)

  defp module_name(module), do: inspect(module)

  # Stored module names are compared as strings, never turned into atoms.
  defp check_module!(module, key, %{module: stored, seq: seq}) do
    unless stored == module_name(module) do
      raise "#{inspect(key)} holds a state written by #{inspect(stored)} (seq #{seq}), " <>
              "not by #{module_name(module)}. A key belongs to one module: " <>
              "use another key, or delete this key's rows from elm_states."
    end
  end

  # Decodes a stored row and migrates it when its version is not the module's.
  # A migrated state counts as never written, so the first step stores it
  # under the current version.
  defp load!(module, key, %{seq: seq, version: version, state: binary}) do
    state =
      try do
        module.decode(binary)
      rescue
        e ->
          reraise "#{inspect(module)} could not decode the state stored under " <>
                    "#{inspect(key)} (seq #{seq}, version #{version}): " <>
                    "#{Exception.message(e)}. The default decode/1 refuses atoms " <>
                    "this node does not know (binary_to_term with :safe).",
                  __STACKTRACE__
      end

    if version == module.version() do
      {state, %{seq: seq, durable: {:written, module.durable(state)}}}
    else
      {migrate!(module, key, seq, version, state), %{seq: seq, durable: :none}}
    end
  end

  defp migrate!(module, key, seq, version, state) do
    module.migrate(state, version)
  rescue
    e ->
      reraise "#{inspect(module)} could not migrate the state stored under " <>
                "#{inspect(key)} (seq #{seq}) from version #{version} to version " <>
                "#{module.version()}: #{Exception.message(e)}",
              __STACKTRACE__
  end

  # The on_step hook: runs before the step's effects. Appends only a durable
  # projection that differs from the last one written, under the next
  # persisted seq, and prunes every `keep` appends. A raise here crashes the
  # server before anything is performed.
  defp persist(module, key, keep, state, acc) do
    durable = module.durable(state)

    case acc.durable do
      {:written, written} when written === durable ->
        acc

      _ ->
        seq = acc.seq + 1
        encoded = encode!(module, key, durable)
        :ok = Store.append(key, seq, module_name(module), module.version(), encoded)
        appends = acc.appends + 1
        if rem(appends, keep) == 0, do: prune(key, keep)
        %{seq: seq, durable: {:written, durable}, appends: appends}
    end
  end

  # Pruning is maintenance: a failure must not crash the server, or it would
  # drop the effects of a step whose state is already written.
  defp prune(key, keep) do
    Store.prune(key, keep)
  rescue
    e ->
      Logger.warning(
        "PersistentElmGenServer could not prune #{inspect(key)} to #{keep} rows: " <>
          Exception.message(e)
      )

      :error
  end

  defp encode!(module, key, durable) do
    encoded =
      try do
        module.encode(durable)
      rescue
        e ->
          reraise "#{inspect(module)}.encode/1 failed for the state of #{inspect(key)}: " <>
                    Exception.message(e),
                  __STACKTRACE__
      end

    if is_binary(encoded),
      do: encoded,
      else: raise("#{inspect(module)}.encode/1 must return a binary, got: #{inspect(encoded)}")
  end
end
