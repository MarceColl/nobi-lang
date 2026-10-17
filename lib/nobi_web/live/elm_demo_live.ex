defmodule NobiWeb.ElmDemoLive do
  @moduledoc """
  Demo of `NobiWeb.ElmLiveView`: a counter, a delayed increment, a dice roll
  and an HTTP fetch, with the runtime timeline and time travel beside them.
  """

  use NobiWeb.ElmLiveView, debug: true
  alias Nobi.Elm.Effect, as: Fx

  @impl true
  def init(_params, _session) do
    model = %{count: 0, pending_incs: 0, roll: nil, url: "https://example.com", fetch: :idle}
    {model, Fx.none()}
  end

  @impl true
  def update({:event, "inc", _}, m), do: {%{m | count: m.count + 1}, Fx.none()}
  def update({:event, "dec", _}, m), do: {%{m | count: m.count - 1}, Fx.none()}

  def update({:event, "inc_later", _}, m),
    do: {%{m | pending_incs: m.pending_incs + 1}, Fx.after_ms(1_000, :delayed_inc)}

  def update(:delayed_inc, m),
    do: {%{m | count: m.count + 1, pending_incs: m.pending_incs - 1}, Fx.none()}

  def update({:event, "roll", _}, m), do: {m, Fx.random(1..6, &{:rolled, &1})}
  def update({:rolled, n}, m), do: {%{m | roll: n}, Fx.none()}

  def update({:event, "fetch", %{"url" => url}}, m) do
    request = [url: url, retry: false, receive_timeout: 5_000]
    {%{m | url: url, fetch: :loading}, Fx.http(request, &{:fetched, &1})}
  end

  def update({:fetched, {:ok, resp}}, m),
    do: {%{m | fetch: {:ok, resp.status, byte_size(IO.iodata_to_binary(resp.body))}}, Fx.none()}

  def update({:fetched, {:error, e}}, m),
    do: {%{m | fetch: :idle}, Fx.flash(:error, "Fetch failed: #{Exception.message(e)}")}

  @impl true
  def view(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="grid gap-8 lg:grid-cols-[minmax(0,22rem)_1fr]">
        <section class="space-y-6">
          <header>
            <h1 class="text-2xl font-semibold tracking-tight">ElmLiveView</h1>
            <p class="mt-1 text-sm text-zinc-500">
              Pure <code>update</code>, effects at the edge. Every msg and effect lands in the timeline.
            </p>
          </header>

          <div class="rounded-2xl border border-zinc-200 p-5 dark:border-zinc-800">
            <div class="flex items-center justify-between">
              <span id="count" class="text-5xl font-semibold tabular-nums">{@model.count}</span>
              <div class="flex gap-2">
                <button id="dec" phx-click="dec" class={btn()}>−</button>
                <button id="inc" phx-click="inc" class={btn()}>+</button>
              </div>
            </div>
            <button id="inc-later" phx-click="inc_later" class={[btn(), "mt-4 w-full"]}>
              +1 in a second
              <span :if={@model.pending_incs > 0} class="ml-1 text-zinc-500">
                ({@model.pending_incs} pending)
              </span>
            </button>
          </div>

          <div class="flex items-center justify-between rounded-2xl border border-zinc-200 p-5 dark:border-zinc-800">
            <span id="roll" class="text-3xl tabular-nums">{@model.roll || "–"}</span>
            <button id="roll-btn" phx-click="roll" class={btn()}>Roll a die</button>
          </div>

          <.form
            for={to_form(%{"url" => @model.url})}
            id="fetch-form"
            phx-submit="fetch"
            class="rounded-2xl border border-zinc-200 p-5 dark:border-zinc-800"
          >
            <.input field={to_form(%{"url" => @model.url})[:url]} type="text" label="URL" />
            <div class="flex items-center justify-between">
              <span id="fetch-result" class="text-sm text-zinc-500">
                <%= case @model.fetch do %>
                  <% :idle -> %>
                    Not fetched
                  <% :loading -> %>
                    <span class="animate-pulse">Fetching…</span>
                  <% {:ok, status, bytes} -> %>
                    HTTP {status} · {bytes} bytes
                <% end %>
              </span>
              <button id="fetch-btn" type="submit" class={btn()} disabled={@model.fetch == :loading}>
                Fetch
              </button>
            </div>
          </.form>
        </section>

        <section class="min-w-0">
          <h2 class="mb-2 text-sm font-medium text-zinc-500">
            Timeline · drag or click a msg to time travel
          </h2>
          <NobiWeb.ElmLiveView.debugger debug={@elm_debug} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp btn,
    do:
      "rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium transition hover:bg-zinc-100 active:scale-95 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
end
