defmodule Kinoko.PersistentElmGenServer do
  @moduledoc """
  A `Kinoko.ElmGenServer` whose state survives restarts and crashes.

  Every changed state is appended to Postgres (`Kinoko.Elm.Store`) under the
  server's key *before* that step's effects run. A server started again under
  the same key resumes from its last written state.
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
