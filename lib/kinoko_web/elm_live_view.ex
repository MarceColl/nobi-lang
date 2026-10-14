defmodule KinokoWeb.ElmLiveView do
  @moduledoc """
  A LiveView with Elm's shape: pure `init`/`update` returning `{model, effects}`,
  and `view/1` rendering `@model`. Same runtime and effects as `Kinoko.ElmGenServer`
  (see `Kinoko.Elm.Effect`), plus LiveView-only effects: `navigate`, `patch`,
  `redirect`, `push_event`, `flash`.

      defmodule KinokoWeb.CounterLive do
        use KinokoWeb.ElmLiveView
        alias Kinoko.Elm.Effect, as: Fx

        def init(_params, _session), do: {%{count: 0}, Fx.none()}

        def update({:event, "inc", _}, m), do: {%{m | count: m.count + 1}, Fx.none()}
        def update({:event, "inc_later", _}, m), do: {m, Fx.after_ms(1_000, {:event, "inc", %{}})}

        def view(assigns) do
          ~H\"""
          <Layouts.app flash={@flash}>
            <button id="inc" phx-click="inc">{@model.count}</button>
          </Layouts.app>
          \"""
        end
      end

  ## Messages

    * `{:event, name, params}` — `phx-*` events
    * `{:params, params, uri}` — `handle_params`, only with `use KinokoWeb.ElmLiveView, params: true`
    * anything else sent to the process arrives as-is

  ## Mount

  LiveView mounts twice: a disconnected render, then the connected process.
  `init/2` runs both times, but only the connected mount performs process
  effects (http, timers, ...); host effects like `navigate` apply to both.

  ## Options

    * `params: true` — route `handle_params` to `update/2`
    * `debug: true` — assign `@elm_debug` and enable time travel; render it
      with `<KinokoWeb.ElmLiveView.debugger debug={@elm_debug} />`

  ## Time travel

  With `debug: true`, the reserved events `"elm:travel"` (`%{"seq" => n}`) and
  `"elm:resume"` move `@model` to the state after msg `n` and back. Nothing is
  re-run: `update/2` is pure, so the runtime's snapshots are the history.
  While travelling, UI events are dropped (the view is frozen on the past),
  but process msgs and effect results keep updating the live state.
  """

  use Phoenix.Component
  import Phoenix.LiveView
  import KinokoWeb.CoreComponents, only: [input: 1]

  alias Kinoko.Elm.{Effect, Runtime, Timeline}

  @callback init(params :: map() | atom(), session :: map()) ::
              {model :: term(), Effect.effects()}
  @callback update(msg :: term(), model :: term()) :: {model :: term(), Effect.effects()}
  @callback view(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  defmacro __using__(opts) do
    params? = Keyword.get(opts, :params, false)
    debug? = Keyword.get(opts, :debug, false)

    quote do
      use KinokoWeb, :live_view
      @behaviour KinokoWeb.ElmLiveView

      @impl Phoenix.LiveView
      def mount(params, session, socket),
        do: KinokoWeb.ElmLiveView.__mount__(__MODULE__, params, session, socket, unquote(debug?))

      @impl Phoenix.LiveView
      def handle_event(event, params, socket),
        do: KinokoWeb.ElmLiveView.__event__(event, params, socket)

      @impl Phoenix.LiveView
      def handle_info(msg, socket), do: KinokoWeb.ElmLiveView.__info__(msg, socket)

      if unquote(params?) do
        @impl Phoenix.LiveView
        def handle_params(params, uri, socket),
          do: KinokoWeb.ElmLiveView.__step__({:params, params, uri}, socket)
      end

      @impl Phoenix.LiveView
      def render(assigns), do: view(assigns)
    end
  end

  @doc false
  def __mount__(module, params, session, socket, debug?) do
    {runtime, effects} =
      Runtime.init(module, {:init, params}, fn -> module.init(params, session) end,
        perform: connected?(socket)
      )

    socket = put_private(socket, :elm_debug?, debug?)
    {:ok, apply_effects(put_runtime(socket, runtime), effects)}
  end

  @doc false
  def __event__("elm:travel", %{"seq" => seq}, %{private: %{elm_debug?: true}} = socket) do
    with {seq, ""} <- Integer.parse(seq),
         {:ok, runtime} <- Runtime.travel(socket.private.elm, seq) do
      {:noreply, put_runtime(socket, runtime)}
    else
      _ -> {:noreply, socket}
    end
  end

  def __event__("elm:resume", _params, %{private: %{elm_debug?: true}} = socket),
    do: {:noreply, put_runtime(socket, Runtime.resume(socket.private.elm))}

  def __event__(event, params, socket) do
    if Runtime.viewing(socket.private.elm),
      do: {:noreply, socket},
      else: __step__({:event, event, params}, socket)
  end

  @doc false
  def __step__(msg, socket),
    do: socket.private.elm |> Runtime.step(msg) |> noreply(socket)

  @doc false
  def __info__(msg, socket),
    do: socket.private.elm |> Runtime.info(msg) |> noreply(socket)

  defp noreply({runtime, effects}, socket),
    do: {:noreply, socket |> put_runtime(runtime) |> apply_effects(effects)}

  # The runtime lives in private so only @model (and @elm_debug) drive re-renders.
  defp put_runtime(socket, runtime) do
    socket = socket |> put_private(:elm, runtime) |> assign(:model, Runtime.view_state(runtime))

    if socket.private.elm_debug?,
      do: assign(socket, :elm_debug, debug_info(runtime)),
      else: socket
  end

  defp debug_info(runtime) do
    viewing = Runtime.viewing(runtime)
    {first, latest} = Runtime.history_range(runtime)

    # A row is in the future when it comes after the viewed msg and its effects.
    {rows, _seq} =
      runtime
      |> Runtime.timeline()
      |> Timeline.rows()
      |> Enum.map_reduce(nil, fn row, last_seq ->
        last_seq = row.seq || last_seq
        {Map.put(row, :future?, viewing != nil and last_seq > viewing), last_seq}
      end)

    %{rows: rows, viewing: viewing, first: first, latest: latest}
  end

  defp apply_effects(socket, effects), do: Enum.reduce(effects, socket, &apply_effect/2)

  defp apply_effect({:navigate, to}, socket), do: push_navigate(socket, to: to)
  defp apply_effect({:patch, to}, socket), do: push_patch(socket, to: to)
  defp apply_effect({:redirect, to}, socket), do: redirect(socket, to: to)
  defp apply_effect({:push_event, event, payload}, socket), do: push_event(socket, event, payload)
  defp apply_effect({:flash, kind, message}, socket), do: put_flash(socket, kind, message)

  defp apply_effect(other, _socket),
    do: raise(ArgumentError, "#{inspect(other)} is not supported in an ElmLiveView")

  ## Debugger

  @doc "Timeline with a time-travel slider. Needs `use KinokoWeb.ElmLiveView, debug: true`."
  attr :debug, :map, required: true

  def debugger(assigns) do
    assigns =
      assign(assigns, :form, to_form(%{"seq" => assigns.debug.viewing || assigns.debug.latest}))

    ~H"""
    <div id="elm-debugger" class="space-y-3">
      <div class="flex items-center gap-3">
        <.form for={@form} id="elm-travel-form" phx-change="elm:travel" class="flex-1">
          <.input
            field={@form[:seq]}
            type="range"
            min={@debug.first}
            max={@debug.latest}
            class="w-full cursor-pointer accent-zinc-900 dark:accent-zinc-100"
          />
        </.form>
        <span class="w-20 text-right font-mono text-xs tabular-nums text-zinc-500">
          {@debug.viewing || @debug.latest} / {@debug.latest}
        </span>
        <button
          id="elm-resume"
          phx-click="elm:resume"
          disabled={is_nil(@debug.viewing)}
          class="rounded-lg bg-zinc-900 px-3 py-1.5 text-xs font-medium text-white transition hover:bg-zinc-700 active:scale-95 disabled:opacity-30 dark:bg-zinc-100 dark:text-zinc-900"
        >
          Resume
        </button>
      </div>

      <p
        :if={@debug.viewing}
        id="elm-travel-banner"
        class="rounded-lg bg-amber-100 px-3 py-2 text-xs text-amber-900 dark:bg-amber-950 dark:text-amber-200"
      >
        Viewing the state after msg {@debug.viewing}. UI events are paused; the live state keeps running.
      </p>

      <div
        id="elm-timeline"
        class="flex h-[32rem] flex-col-reverse overflow-auto rounded-2xl bg-zinc-950 p-3 font-mono text-xs leading-relaxed"
      >
        <div>
          <%= for row <- @debug.rows do %>
            <button
              :if={row.seq}
              type="button"
              phx-click="elm:travel"
              phx-value-seq={row.seq}
              class={[
                "block w-full whitespace-pre rounded px-1 text-left transition hover:bg-zinc-800",
                row.seq == @debug.viewing && "bg-amber-500/20 text-amber-200",
                row.seq != @debug.viewing && !row.future? && "text-zinc-200",
                row.future? && "text-zinc-600"
              ]}
            >
              {row.text}
            </button>
            <div
              :if={!row.seq}
              class={[
                "whitespace-pre px-1",
                if(row.future?, do: "text-zinc-700", else: "text-zinc-500")
              ]}
            >
              {row.text}
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
