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

  @views %{"graph" => :graph, "code" => :code, "data" => :data}

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, view: Map.get(@views, params["view"], :graph))}

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

    {app_count, store_count} =
      case Universe.graph(u) do
        %{apps: apps, stores: stores} -> {length(apps), length(stores)}
        _ -> {length(apps), 0}
      end

    socket
    |> assign(health: Universe.health(u), head: length(history))
    |> assign(
      app_count: app_count,
      store_count: store_count,
      symbol_count: length(symbols),
      staged_count: length(staged)
    )
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

  # Until the System, Code and Data stages land, every view shows the
  # universe's summary in the stage.
  defp heading(%{view: :graph} = a),
    do:
      {"System",
       "#{count(a.app_count, "app")} · #{count(a.store_count, "store")} · #{a.staged_count} staged"}

  defp heading(%{view: :code} = a),
    do: {"Code", "#{count(a.symbol_count, "symbol")} · #{a.staged_count} staged"}

  defp heading(%{view: :data}), do: {"Data", ""}

  @impl true
  def render(assigns) do
    {title, subtitle} = heading(assigns)
    assigns = assign(assigns, title: title, subtitle: subtitle)

    ~H"""
    <.shell
      flash={@flash}
      console={@console}
      streams={@streams}
      view={@view}
      title={@title}
      subtitle={@subtitle}
      commit={"##{@head}"}
    >
      <.page>
        <div class="flex items-center gap-[9px]">
          <span
            id="universe-name"
            class="font-(family-name:--k-display) text-[25px] font-medium tracking-normal"
          >
            {@universe}
          </span>
          <%= case @health do %>
            <% :ok -> %>
              <span
                id="health"
                data-state="ok"
                class="text-[11.5px] text-(--k-mint) bg-(--k-mint-chip) border border-(--k-mint-chip-border) px-[8px] py-[2px] rounded-[5px]"
              >
                healthy
              </span>
            <% _ -> %>
              <span
                id="health"
                data-state="degraded"
                class="text-[11.5px] text-(--k-amber-text) bg-(--k-amber-chip) border border-(--k-amber-chip-border) px-[8px] py-[2px] rounded-[5px]"
              >
                degraded
              </span>
          <% end %>
        </div>

        <div
          :if={match?({:degraded, _}, @health)}
          id="degraded-banner"
          class="rounded-[9px] border border-(--k-amber-chip-border) bg-(--k-amber-chip) px-[12px] py-[9px] text-[12.5px] text-(--k-amber-text) flex flex-col gap-[6px]"
        >
          <span class="font-medium">This universe's committed code no longer typechecks.</span>
          <span :for={r <- elem(@health, 1)} data-reason>
            <span class="font-(family-name:--k-mono)">{r[:name]}</span> [{r[:code]}] {r[:message]}
          </span>
        </div>

        <.section title="Apps" id="apps-section">
          <div id="apps" phx-update="stream" class={table_class()}>
            <div id="empty-1" class={empty_class()}>No apps committed.</div>
            <div :for={{dom_id, a} <- @streams.apps} id={dom_id} class={row_rule_class()}>
              <span class="font-(family-name:--k-mono) font-medium">{a.symbol}</span>
              <div class="flex-1"></div>
              <.link
                :for={d <- a.serving}
                navigate={~p"/_/d/#{d}"}
                class="font-(family-name:--k-mono) text-[11.5px] text-(--k-violet) hover:text-(--k-violet-hover)"
              >
                {d}
              </.link>
              <span :if={a.serving == []} class="text-[11.5px] text-(--k-faint)">not served</span>
            </div>
          </div>
        </.section>

        <.section title="Route tables" id="routes-section">
          <div id="route-tables" phx-update="stream" class="flex flex-col gap-[9px]">
            <div id="empty-2" class={empty_class()}>No route tables.</div>
            <div :for={{dom_id, t} <- @streams.tables} id={dom_id} class={table_class()}>
              <div class="px-[12px] py-[7px] bg-(--k-tint) border-b border-(--k-line) font-(family-name:--k-mono) text-[11.5px] font-medium">
                {t.name}
              </div>
              <div :for={e <- t.entries} data-pattern={pattern(e)} class={row_rule_class()}>
                <span class="font-(family-name:--k-mono) text-(--k-violet)">{pattern(e)}</span>
                <div class="flex-1"></div>
                <span class="font-(family-name:--k-mono) text-[11.5px] text-(--k-dim)">
                  → {e.app}
                </span>
              </div>
            </div>
          </div>
        </.section>

        <.section title="Staged patches" id="staged-section">
          <div id="staged" phx-update="stream" class="flex flex-col gap-[9px]">
            <div id="empty-3" class={empty_class()}>Nothing staged.</div>
            <div
              :for={{dom_id, p} <- @streams.staged}
              id={dom_id}
              class="rounded-[9px] border border-(--k-amber-chip-border) bg-(--k-amber-chip) px-[12px] py-[9px] text-[12.5px] flex flex-col gap-[6px]"
            >
              <span class="font-(family-name:--k-mono) font-medium">{p.id}</span>
              <span :for={r <- p.reasons} data-reason class="text-(--k-amber-text)">
                <span :if={r[:name]} class="font-(family-name:--k-mono)">{r[:name]}</span>
                [{r[:code]}] {r[:message]}
              </span>
            </div>
          </div>
        </.section>

        <.section title="Symbols" id="symbols-section">
          <div id="symbols" phx-update="stream" class={table_class()}>
            <div id="empty-4" class={empty_class()}>No symbols committed.</div>
            <div :for={{dom_id, s} <- @streams.symbols} id={dom_id} class={row_rule_class()}>
              <span class="font-(family-name:--k-mono) font-medium">{s.symbol}</span>
              <div class="flex-1"></div>
              <span class="font-(family-name:--k-mono) text-[11.5px] text-(--k-dim) truncate">
                {s.signature}
              </span>
            </div>
          </div>
        </.section>

        <.section title="History" id="history-section">
          <div id="history" phx-update="stream" class={table_class()}>
            <div id="empty-5" class={empty_class()}>No commits yet.</div>
            <div :for={{dom_id, h} <- @streams.history} id={dom_id} class={row_rule_class()}>
              <span class="font-(family-name:--k-mono) text-(--k-faint)">#{h.n}</span>
              <span class="font-medium">{Enum.join(h.patches, ", ")}</span>
              <div class="flex-1"></div>
              <span class="font-(family-name:--k-mono) text-[11.5px] flex flex-wrap gap-[6px]">
                <span :for={s <- h.live} class="text-(--k-mint)">+{s}</span>
                <span :for={s <- h.gone} class="text-(--k-red)">-{s}</span>
              </span>
            </div>
          </div>
        </.section>
      </.page>
    </.shell>
    """
  end
end
