defmodule Nobi.ElmGenServer do
  @moduledoc """
  A GenServer where all logic is pure and side effects happen at the edge, Elm style.

  A module implementing this behaviour never touches the outside world. It receives
  messages and returns `{new_state, effects}`. Effects are *descriptions* of work
  (see `Nobi.Elm.Effect`); the runtime performs them asynchronously, outside the
  server process, and routes the outcome back as a message:

      defmodule Pinger do
        use Nobi.ElmGenServer
        alias Nobi.Elm.Effect, as: Fx

        def init(url), do: {%{url: url, status: nil}, Fx.dispatch(:ping)}

        def update({:call, from, :status}, s), do: {s, Fx.reply(from, s.status)}

        def update(:ping, s),
          do: {s, Fx.http([method: :get, url: s.url], &{:pinged, &1})}

        def update({:pinged, {:ok, resp}}, s),
          do: {%{s | status: resp.status}, Fx.after_ms(5_000, :ping)}

        def update({:pinged, {:error, _}}, s),
          do: {%{s | status: :down}, Fx.after_ms(5_000, :ping)}
      end

  `update(:ping, s)` returns immediately; the server keeps handling messages while
  the request is in flight, and `{:pinged, result}` arrives later like any other msg.

  ## Messages

  Everything arrives through `update/2`:

    * casts and plain process messages arrive as-is
    * calls arrive as `{:call, from, request}`; answer with `Effect.reply(from, value)`,
      in that update or any later one (e.g. once an http response comes back)

  ## Timeline

  `print_timeline/1` shows every msg, the effects it started and, for msgs
  produced by an effect, which one and how long it took. See `Nobi.Elm.Timeline`.
  """

  use GenServer

  alias Nobi.Elm.{Effect, Host, Runtime, Timeline}

  @callback init(args :: term()) :: {state :: term(), Effect.effects()}
  @callback update(msg :: term(), state :: term()) :: {state :: term(), Effect.effects()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Nobi.ElmGenServer

      def child_spec(arg) do
        %{id: __MODULE__, start: {Nobi.ElmGenServer, :start_link, [__MODULE__, arg]}}
      end

      defoverridable child_spec: 1
    end
  end

  ## Client API

  def start_link(module, args, opts \\ []) do
    GenServer.start_link(__MODULE__, {module, args}, opts)
  end

  def call(server, request, timeout \\ 5000), do: GenServer.call(server, request, timeout)

  def cast(server, msg), do: GenServer.cast(server, msg)

  defdelegate timeline(server), to: Timeline, as: :fetch
  defdelegate print_timeline(server), to: Timeline, as: :print

  ## GenServer callbacks

  @impl true
  def init({module, args}),
    do: module |> Runtime.init({:init, args}, fn -> module.init(args) end) |> Host.init()

  @impl true
  def handle_call(request, from, runtime), do: Host.handle_call(request, from, runtime)

  @impl true
  def handle_cast(msg, runtime), do: Host.handle_cast(msg, runtime)

  @impl true
  def handle_info(msg, runtime), do: Host.handle_info(msg, runtime)
end
