defmodule KinokoWeb.Console.UniverseLive do
  @moduledoc """
  `/_/u/:universe`: one universe's apps (linked to the deployments serving
  them), route tables, symbols, staged patches with their reasons, history
  and health. Refreshes on every commit once connected.
  """

  use KinokoWeb, :live_view

  import KinokoWeb.Console.Components

  alias Kinoko.{Deployment, Universe}

  @impl true
  def mount(%{"universe" => universe}, _session, socket) do
    if known?(universe) do
      if connected?(socket), do: Universe.subscribe(universe)

      {:ok,
       socket
       |> assign(universe: universe, page_title: universe)
       |> configure_streams()
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "No universe named #{universe}")
       |> push_navigate(to: ~p"/_")}
    end
  end

  @impl true
  def handle_info({:committed, universe, _}, %{assigns: %{universe: universe}} = socket),
    do: {:noreply, load(socket, true)}

  def handle_info(_, socket), do: {:noreply, socket}

  # Dom ids are the items' own `id`, not prefixed with the stream's name.
  defp configure_streams(socket) do
    Enum.reduce(~w(apps tables symbols staged history)a, socket, fn name, socket ->
      stream_configure(socket, name, dom_id: & &1.id)
    end)
  end

  defp known?(universe) do
    case Universe.list() do
      list when is_list(list) -> Enum.any?(list, &(&1.name == universe))
      _ -> false
    end
  end

  defp load(socket, reset? \\ false) do
    u = socket.assigns.universe
    symbols = listed(Universe.symbols(u))
    staged = listed(Universe.staged(u))
    history = listed(Universe.history(u))
    routes = routes(u)
    deployments = Enum.filter(Deployment.list(), &(&1.universe == u))

    apps =
      for %{symbol: s, signature: "app"} <- symbols do
        serving =
          for d <- deployments,
              Enum.any?(Map.get(routes, d.routes, []), &(&1.app == s)),
              do: d.name

        %{id: "app-" <> s, symbol: s, serving: serving}
      end

    tables =
      for {name, entries} <- Enum.sort(routes),
          do: %{id: "route-table-" <> name, name: name, entries: entries}

    rounds =
      history
      |> Enum.with_index(1)
      |> Enum.reverse()
      |> Enum.map(fn {round, n} ->
        %{
          id: "history-#{n}",
          n: n,
          patches: round.ids,
          live: for({:live, s, _} <- round.entries, do: s),
          gone: for({:gone, s} <- round.entries, do: s)
        }
      end)

    socket
    |> assign(health: Universe.health(u), head: length(history))
    |> stream(:apps, apps, reset: reset?)
    |> stream(:tables, tables, reset: reset?)
    |> stream(:symbols, for(s <- symbols, do: Map.put(s, :id, "symbol-" <> s.symbol)),
      reset: reset?
    )
    |> stream(:staged, for(p <- staged, do: Map.put(p, :id, "staged-" <> p.id)), reset: reset?)
    |> stream(:history, rounds, reset: reset?)
  end

  defp listed(list) when is_list(list), do: list
  defp listed(_), do: []

  defp routes(universe) do
    case Universe.routes(universe) do
      %{} = routes -> routes
      _ -> %{}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell flash={@flash} crumbs={[{@universe, nil}]}>
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 id="universe-name" class="font-mono text-2xl font-semibold tracking-tight">
            {@universe}
          </h1>
          <p class="mt-1 text-sm text-zinc-500">{@head} commits</p>
        </div>
        <%= case @health do %>
          <% :ok -> %>
            <.badge id="health" data-state="ok" tone={:ok}>
              <.icon name="hero-check-circle" class="size-4" /> healthy
            </.badge>
          <% _ -> %>
            <.badge id="health" data-state="degraded" tone={:warn}>
              <.icon name="hero-exclamation-triangle" class="size-4" /> degraded
            </.badge>
        <% end %>
      </div>

      <div
        :if={match?({:degraded, _}, @health)}
        id="degraded-banner"
        class="rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200"
      >
        <p class="font-semibold">This universe's committed code no longer typechecks.</p>
        <ul class="mt-2 list-disc space-y-1 pl-5">
          <li :for={r <- elem(@health, 1)} data-reason>
            <span class="font-mono">{r[:name]}</span> [{r[:code]}] {r[:message]}
          </li>
        </ul>
      </div>

      <.section title="Apps" id="apps-section">
        <div id="apps" phx-update="stream" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <div id="empty-1" class="hidden only:block text-sm text-zinc-500">No apps committed.</div>
          <div
            :for={{dom_id, a} <- @streams.apps}
            id={dom_id}
            class={[card_class(), "p-4 hover:border-rose-300 dark:hover:border-rose-800"]}
          >
            <div class="font-mono text-sm font-semibold">{a.symbol}</div>
            <div class="mt-2 flex flex-wrap gap-1.5">
              <.link :for={d <- a.serving} navigate={~p"/_/d/#{d}"}>
                <.badge tone={:ok}>
                  <.icon name="hero-globe-alt" class="size-3.5" /> {d}
                </.badge>
              </.link>
              <span :if={a.serving == []} class="text-xs text-zinc-400">not served</span>
            </div>
          </div>
        </div>
      </.section>

      <.section title="Route tables" id="routes-section">
        <div id="route-tables" phx-update="stream" class="grid gap-3 lg:grid-cols-2">
          <div id="empty-2" class="hidden only:block text-sm text-zinc-500">No route tables.</div>
          <div
            :for={{dom_id, t} <- @streams.tables}
            id={dom_id}
            class={[card_class(), "overflow-hidden"]}
          >
            <div class="border-b border-zinc-100 px-4 py-2 font-mono text-sm font-semibold dark:border-zinc-800">
              {t.name}
            </div>
            <ul class="divide-y divide-zinc-100 dark:divide-zinc-800">
              <li
                :for={e <- t.entries}
                data-pattern={pattern(e)}
                class="flex items-center justify-between gap-3 px-4 py-2 text-sm transition hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
              >
                <code class="text-rose-600 dark:text-rose-400">{pattern(e)}</code>
                <span class="flex items-center gap-1 font-mono text-xs text-zinc-500">
                  <.icon name="hero-arrow-right" class="size-3" /> {e.app}
                </span>
              </li>
            </ul>
          </div>
        </div>
      </.section>

      <.section title="Staged patches" id="staged-section">
        <div id="staged" phx-update="stream" class="space-y-3">
          <div id="empty-3" class="hidden only:block text-sm text-zinc-500">Nothing staged.</div>
          <div
            :for={{dom_id, p} <- @streams.staged}
            id={dom_id}
            class="rounded-xl border border-amber-200 bg-amber-50/60 p-4 dark:border-amber-900 dark:bg-amber-950/40"
          >
            <div class="font-mono text-sm font-semibold">{p.id}</div>
            <ul class="mt-2 space-y-1 text-sm text-amber-900 dark:text-amber-200">
              <li :for={r <- p.reasons} data-reason class="flex gap-2">
                <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                <span>
                  <span :if={r[:name]} class="font-mono">{r[:name]}</span>
                  <span class="opacity-60">[{r[:code]}]</span>
                  {r[:message]}
                </span>
              </li>
            </ul>
          </div>
        </div>
      </.section>

      <.section title="Symbols" id="symbols-section">
        <div
          id="symbols"
          phx-update="stream"
          class={[card_class(), "divide-y divide-zinc-100 dark:divide-zinc-800"]}
        >
          <div id="empty-4" class="hidden only:block p-4 text-sm text-zinc-500">
            No symbols committed.
          </div>
          <div
            :for={{dom_id, s} <- @streams.symbols}
            id={dom_id}
            class="flex flex-wrap items-baseline justify-between gap-x-4 px-4 py-2 transition hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
          >
            <span class="font-mono text-sm font-medium">{s.symbol}</span>
            <code class="truncate text-xs text-zinc-500">{s.signature}</code>
          </div>
        </div>
      </.section>

      <.section title="History" id="history-section">
        <ol id="history" phx-update="stream" class="space-y-2">
          <li id="empty-5" class="hidden only:block text-sm text-zinc-500">No commits yet.</li>
          <li
            :for={{dom_id, h} <- @streams.history}
            id={dom_id}
            class={[card_class(), "flex flex-wrap items-start gap-3 p-3"]}
          >
            <.badge tone={:info}>#{h.n}</.badge>
            <div class="min-w-0 flex-1 text-sm">
              <div class="font-medium">{Enum.join(h.patches, ", ")}</div>
              <div class="mt-1 flex flex-wrap gap-1 font-mono text-xs">
                <span :for={s <- h.live} class="text-emerald-600 dark:text-emerald-400">+{s}</span>
                <span :for={s <- h.gone} class="text-rose-600 dark:text-rose-400">-{s}</span>
              </div>
            </div>
          </li>
        </ol>
      </.section>
    </.shell>
    """
  end
end
