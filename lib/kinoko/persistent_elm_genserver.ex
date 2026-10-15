defmodule Kinoko.PersistentElmGenServer do
  @moduledoc """
  A `Kinoko.ElmGenServer` whose state survives restarts and crashes.

  Every changed state is appended to Postgres (`Kinoko.Elm.Store`, table
  `elm_states`) under the server's key *before* that step's effects run. A
  server started again under the same key resumes from its last written state.
  `init/1` and `update/2` are the same as in `Kinoko.ElmGenServer`; so are
  `call/3` and `cast/2`, which also take the key in place of a pid.

  ## Example

      iex> defmodule Counter do
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
      iex> {:ok, pid} = Kinoko.PersistentElmGenServer.start_link(Counter, 0, key: "counter:demo")
      iex> Kinoko.PersistentElmGenServer.call("counter:demo", :inc)
      1
      iex> Kinoko.PersistentElmGenServer.call("counter:demo", :inc)
      2
      iex> GenServer.stop(pid)
      :ok
      iex> {:ok, _pid} = Kinoko.PersistentElmGenServer.start_link(Counter, 0, key: "counter:demo")
      iex> Kinoko.PersistentElmGenServer.call("counter:demo", :count)
      2

  The second start found a stored state, so it skipped `init/1` (and its
  argument) and called `resume/1` with the count of 2. Under a supervisor,
  use the generated child spec: `{Counter, key: "counter:demo", args: 0}`
  (`id: {Counter, key}`, so one module can run under many keys).

  One live process per key per node, enforced by the `Kinoko.Elm.Registry`
  name: a second `start_link` under a running key returns
  `{:error, {:already_started, pid}}` and writes nothing. `whereis/1` finds it.

  ## Callbacks

  Besides `init/1` and `update/2`, all optional (`use` provides the defaults):

    * `version/0`, default `1`, stored with every row
    * `migrate(state, from_version)`, see below
    * `resume(state) :: {state, effects}`, called *instead of* `init/1` when a
      stored state exists. Default `{state, []}`. Restart timers here: an
      `Effect.after_ms/2` pending when the old process died died with it.
    * `encode(state) :: binary` and `decode(binary) :: state`, see below

  ## Durability

    * **Written before effects.** The write is a `Kinoko.Elm.Runtime` `on_step`
      hook, which runs after `init`/`update` returns and before any effect of
      that step is performed. A reply or a message is never released for a
      state that was not written. If the write fails (the DB is down, `encode`
      raises), the server crashes, the step's effects are never performed, and
      a restart resumes the last written state.
    * **Only changes are written.** A step whose state is `===` the last one
      written appends nothing. Otherwise it appends the next `seq`, continuing
      across restarts from the stored one.
    * **In-flight effects are lost.** An HTTP request, task or timer started
      before a crash does not come back to the new process, and messages in
      the mailbox are lost as with any GenServer. Callers retry; `resume/1`
      restarts timers. Durable effects (an intent log with redelivery) are out
      of scope.
    * **Stale pids.** `term_to_binary` stores pids, refs and funs, so a state
      holding them (e.g. a list of `from`s waiting for a reply) boots fine, but
      after a restart they point at processes that may be gone. Sending to them
      is harmless; waiting on them is not. Clear such fields in `resume/1`.

  ## Versions and `migrate/2`

  Every row stores `version/0`. On boot, when the stored version differs from
  the module's, `migrate(state, stored_version)` must return the state in the
  current shape. The default raises, naming both versions, so a version bump
  without a migration refuses to boot rather than run on a state it does not
  understand. A migrated state is always written once (under the new version)
  before any effect runs; if it then fails `encode/1`, boot crashes with an
  error naming the module and key.

  ## Storage cost and pruning

  Each changed step stores the *whole* encoded state: a 5 MB state that
  changes on every message writes 5 MB per message. Keep persistent state
  small, or override `encode/1` to store less. `keep:` on `start_link/3`
  (default 100) bounds the rows: after every `keep` appends a process
  deletes all but the newest `keep` rows of its key. The append count starts
  over in each process, so a key restarted often holds more rows until its
  current process reaches `keep` appends. Rows are never updated; `Kinoko.Elm.Store.history/2` reads
  them back.

  ## Custom encoding

  The defaults are `:erlang.term_to_binary/1` and
  `:erlang.binary_to_term(binary, [:safe])`. `:safe` never creates atoms from
  stored data, so a binary naming an atom this node does not know (a renamed
  module, a removed tag) refuses to boot with an error naming the key and seq
  rather than leaking atoms.

  Override both to store something other than the live term. The code DB
  server (piece 3) holds a `Kinoko.Lang` universe: its `encode/1` stores only
  the universe's `history` (rounds) and `texts`, and its `decode/1` rebuilds
  the universe with `Kinoko.Lang.restore/2`, which checks the code again on
  every boot.
  """

  use GenServer

  alias Kinoko.Elm.{Effect, Host, Runtime, Store, Timeline}

  @callback init(args :: term()) :: {state :: term(), Effect.effects()}
  @callback update(msg :: term(), state :: term()) :: {state :: term(), Effect.effects()}
  @callback version() :: pos_integer()
  @callback migrate(state :: term(), from_version :: pos_integer()) :: term()
  @callback resume(state :: term()) :: {state :: term(), Effect.effects()}
  @callback encode(state :: term()) :: binary()
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

      def encode(state), do: :erlang.term_to_binary(state)

      def decode(binary), do: :erlang.binary_to_term(binary, [:safe])

      defoverridable child_spec: 1, version: 0, migrate: 2, resume: 1, encode: 1, decode: 1
    end
  end

  ## Client API

  @doc """
  Starts `module` under `key: key` (a string), at most one live process per
  key on this node. `keep:` (default 100) bounds the rows kept per key.
  """
  def start_link(module, args, opts) do
    key = Keyword.fetch!(opts, :key)
    keep = Keyword.get(opts, :keep, 100)

    unless is_binary(key), do: raise(ArgumentError, "key must be a string, got: #{inspect(key)}")

    unless is_integer(keep) and keep > 0,
      do: raise(ArgumentError, "keep must be a positive integer")

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
    raise "#{inspect(module)} found a state stored at version #{from_version}, " <>
            "but is at version #{module.version()}. Implement migrate/2 " <>
            "to bring a version #{from_version} state up to date."
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
          {{:init, args}, fn -> module.init(args) end, %{seq: -1, state: :none}}

        {:ok, row} ->
          {state, written} = load!(module, key, row)
          {{:resume, row.seq}, fn -> module.resume(state) end, written}
      end

    persist = fn state, _seq, acc -> persist(module, key, keep, state, acc) end
    hook = {persist, Map.put(written, :appends, 0)}

    module |> Runtime.init(init_msg, init_fun, on_step: hook) |> Host.init()
  end

  @impl true
  def handle_call(request, from, runtime), do: Host.handle_call(request, from, runtime)

  @impl true
  def handle_cast(msg, runtime), do: Host.handle_cast(msg, runtime)

  @impl true
  def handle_info(msg, runtime), do: Host.handle_info(msg, runtime)

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
      {state, %{seq: seq, state: {:written, state}}}
    else
      {module.migrate(state, version), %{seq: seq, state: :none}}
    end
  end

  # The on_step hook: runs before the step's effects. Appends only a state
  # that differs from the last one written, under the next persisted seq,
  # and prunes every `keep` appends. A raise here crashes the server before
  # anything is performed.
  defp persist(_module, _key, _keep, state, %{state: {:written, written}} = acc)
       when written === state,
       do: acc

  defp persist(module, key, keep, state, acc) do
    seq = acc.seq + 1
    :ok = Store.append(key, seq, module.version(), encode!(module, key, state))
    appends = acc.appends + 1
    if rem(appends, keep) == 0, do: Store.prune(key, keep)
    %{seq: seq, state: {:written, state}, appends: appends}
  end

  defp encode!(module, key, state) do
    encoded =
      try do
        module.encode(state)
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
