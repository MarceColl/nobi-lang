defmodule KinokoWeb.Console.UniverseLive do
  @moduledoc """
  `/_/u/:universe`: one universe's stages. `?view=graph` (the default) is
  the System graph, ported from the Kinoko Vellum prototype's
  `graphStage()`: its apps and stores laid out by
  `KinokoWeb.Console.GraphLayout`, joined by what they read and write,
  with `?sel=<symbol>` opening the inspector (`panelFor()`). The camera
  (pan, zoom, fit) is the `GraphCamera` hook's. `?view=code` and
  `?view=data` leave the stage empty for now.

  Refreshes on every commit once connected.
  """

  use KinokoWeb, :live_view

  import KinokoWeb.Console.Components

  alias Kinoko.{Data, Deployment, Universe}
  alias Kinoko.Exec.Show
  alias KinokoWeb.Console.GraphLayout

  # The inspector's rows sample, as the prototype's `EXPENSES.slice(0, 4)`.
  @sample 4

  @impl true
  def mount(%{"universe" => universe}, _session, socket) do
    if known?(universe) do
      if connected?(socket), do: Universe.subscribe(universe)

      {:ok,
       socket
       |> assign(universe: universe, page_title: universe, view: :graph, sel: nil)
       |> stream_configure(:nodes, dom_id: & &1.id)
       |> stream_configure(:edges, dom_id: & &1.id)}
    else
      {:ok,
       socket
       |> put_flash(:error, "No universe named #{universe}")
       |> push_navigate(to: ~p"/_")}
    end
  end

  @views %{"graph" => :graph, "code" => :code, "data" => :data}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(view: Map.get(@views, params["view"], :graph), sel: params["sel"])
     |> load()}
  end

  @impl true
  def handle_event("graph:deselect", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/_/u/#{socket.assigns.universe}")}

  @impl true
  def handle_info({:committed, universe, _}, %{assigns: %{universe: universe}} = socket),
    do: {:noreply, load(socket)}

  def handle_info(_, socket), do: {:noreply, socket}

  defp known?(universe) do
    case Universe.list() do
      list when is_list(list) -> Enum.any?(list, &(&1.name == universe))
      _ -> false
    end
  end

  ## Loading

  defp load(socket) do
    u = socket.assigns.universe
    head = length(listed(Universe.history(u)))
    graph = Universe.graph(u)

    {app_count, store_count} =
      case graph do
        %{apps: apps, stores: stores} -> {length(apps), length(stores)}
        _ -> {length(listed(Universe.apps(u))), 0}
      end

    socket =
      assign(socket,
        head: head,
        app_count: app_count,
        store_count: store_count,
        symbol_count: length(listed(Universe.symbols(u))),
        staged_count: length(listed(Universe.staged(u)))
      )

    if socket.assigns.view == :graph,
      do: load_graph(socket, graph),
      else: assign(socket, stage: :none, panel: nil)
  end

  defp load_graph(socket, %{apps: _} = graph) do
    %{universe: u, sel: sel, head: head} = socket.assigns

    if head == 0 do
      assign(socket, stage: :empty, panel: nil)
    else
      deployment = Enum.find(Deployment.list(), &(&1.universe == u))
      rows = rows(deployment)
      layout = GraphLayout.layout(graph)

      nodes =
        for n <- layout.nodes,
            do:
              Map.merge(n, %{
                selected: n.symbol == sel,
                rows: rows_label(rows, n.symbol),
                path: ~p"/_/u/#{u}?#{[sel: n.symbol]}"
              })

      socket
      |> assign(
        stage: :graph,
        world: Map.take(layout, [:w, :h, :cw, :ch]),
        panel: panel(sel, graph, deployment, rows, u)
      )
      |> stream(:nodes, nodes, reset: true)
      |> stream(:edges, layout.edges, reset: true)
    end
  end

  defp load_graph(socket, {:error, %{code: "degraded"}}) do
    reasons =
      case Universe.health(socket.assigns.universe) do
        {:degraded, reasons} -> reasons
        _ -> []
      end

    assign(socket, stage: {:degraded, reasons}, panel: nil)
  end

  defp load_graph(socket, {:error, reason}),
    do: assign(socket, stage: {:error, reason_text(reason)}, panel: nil)

  # `%{model => row count}` of the deployment's file, or nil with no
  # deployment (IMPLEMENTATION-MAP §3: `no data`).
  defp rows(nil), do: nil
  defp rows(deployment), do: Map.new(Data.stats(deployment.name), &{&1.model, &1.rows})

  defp rows_label(nil, _symbol), do: "no data"
  defp rows_label(rows, symbol), do: count(Map.get(rows, symbol, 0), "row")

  defp listed(list) when is_list(list), do: list
  defp listed(_), do: []

  ## The inspector (`panelFor()`)

  defp panel(nil, _graph, _deployment, _rows, _u), do: nil

  defp panel(sel, graph, deployment, rows, u) do
    cond do
      app = Enum.find(graph.apps, &(&1.symbol == sel)) ->
        app_panel(app, graph, u)

      store = Enum.find(graph.stores, &(&1.symbol == sel)) ->
        store_panel(store, graph, deployment, rows, u)

      true ->
        nil
    end
  end

  defp app_panel(app, graph, u) do
    writes = for %{from: f, to: t, kind: :writes} <- graph.edges, f == app.symbol, do: t
    reads = for %{from: f, to: t, kind: :reads} <- graph.edges, f == app.symbol, do: t

    data =
      Enum.join(
        if(writes == [], do: [], else: ["writes " <> Enum.join(writes, ", ")]) ++
          if(reads == [], do: [], else: ["reads " <> Enum.join(reads, ", ")]),
        " · "
      )

    route_key = if length(app.routes) == 1, do: "route", else: "routes"

    rows =
      [
        app.routes != [] && row(route_key, Enum.join(app.routes, " · ")),
        model_row(app.symbol, u),
        data != "" && row("data", data),
        row("serving", serving(app.symbol, u))
      ]
      |> Enum.filter(& &1)

    %{kind: :app, name: app.symbol, sub: "Screen", rows: rows}
  end

  defp model_row(app, u) do
    model = app <> ".Model"

    with {:ok, image} <- Universe.image(u),
         fields when is_list(fields) <- Map.get(image.module.__yabu__(:models), model) do
      row("model", "#{model} · #{count(length(fields), "field")}")
    else
      _ -> false
    end
  end

  # The deployments of this universe whose route table opens `app`.
  defp serving(app, u) do
    routes =
      case Universe.routes(u) do
        %{} = routes -> routes
        _ -> %{}
      end

    names =
      for d <- Deployment.list(),
          d.universe == u,
          Enum.any?(Map.get(routes, d.routes, []), &(&1.app == app)),
          do: d.name

    if names == [], do: "not served", else: Enum.join(names, ", ")
  end

  defp store_panel(store, graph, deployment, rows, u) do
    by = fn kind ->
      case for(%{from: f, to: t, kind: ^kind} <- graph.edges, t == store.symbol, do: f) do
        [] -> "none"
        apps -> Enum.join(apps, ", ")
      end
    end

    n = rows && Map.get(rows, store.symbol, 0)

    %{
      kind: :store,
      name: store.symbol,
      sub: "Model store · " <> rows_label(rows, store.symbol),
      rows: [
        row("fields", Enum.join(store.fields, " · "), true),
        row("written by", by.(:writes)),
        row("read by", by.(:reads)),
        row("layer", if(deployment, do: deployment.name, else: "no data"))
      ],
      data_path: ~p"/_/u/#{u}?#{[view: "data", store: store.symbol]}",
      sample: sample(deployment, store.symbol, n, u),
      more: if(n && n > @sample, do: n - @sample, else: 0)
    }
  end

  defp row(k, v, mono \\ false), do: %{k: k, v: v, mono: mono}

  # The newest rows of `model`, at most `@sample`, as the prototype's
  # three cells: the first field, the middle ones, the last one.
  defp sample(deployment, model, n, u) when is_integer(n) and n > 0 do
    with {:ok, image} <- Universe.image(u),
         models = image.module.__yabu__(:models),
         {:ok, repo} <- Data.open(deployment.name),
         {:ok, list} <- Data.list(repo, model, models) do
      for {:rec, _, values} <- list |> Enum.reverse() |> Enum.take(@sample) do
        fields = for {f, _, _} <- Map.get(models, model, []), f != "id", do: shown(values[f])

        case fields do
          [] -> {"", "", ""}
          [a] -> {a, "", ""}
          [a, b] -> {a, "", b}
          [a | rest] -> {a, rest |> Enum.drop(-1) |> Enum.join(" · "), List.last(rest)}
        end
      end
    else
      _ -> []
    end
  end

  defp sample(_deployment, _model, _n, _u), do: []

  defp shown(s) when is_binary(s), do: s
  defp shown(v), do: Show.show(v)

  ## Rendering

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
      <%= case @stage do %>
        <% :graph -> %>
          <.graph_stage streams={@streams} world={@world} selected={@panel != nil} />
        <% :empty -> %>
          <div class="flex-1 min-w-0 overflow-y-auto px-[18px] py-[16px] flex flex-col gap-[8px] bg-(--k-paper)">
            <div id="graph-empty" class="max-w-[420px] flex flex-col gap-[9px] pt-[50px]">
              <span class="font-(family-name:--k-display) text-[18px] font-medium">
                Nothing committed
              </span>
              <span class="text-[13px] leading-[1.6] text-(--k-dim) [text-wrap:pretty]">
                Stage a patch through the MCP or the REPL below.
              </span>
            </div>
          </div>
        <% {:degraded, reasons} -> %>
          <.degraded_stage title="Committed code no longer typechecks" reasons={reasons} />
        <% {:error, text} -> %>
          <.degraded_stage title={text} reasons={[]} />
        <% :none -> %>
      <% end %>
      <:inspector :if={@panel}>
        <.inspector panel={@panel} universe={@universe} />
      </:inspector>
    </.shell>
    """
  end

  attr :streams, :any, required: true
  attr :world, :map, required: true
  attr :selected, :boolean, required: true

  # graphStage(): the canvas, its world (SVG edges under the nodes), the
  # hint, then the zoom strip with the legend.
  defp graph_stage(assigns) do
    ~H"""
    <div id="graph" class="flex-1 min-w-0 min-h-0 flex flex-col">
      <div
        id="graph-canvas"
        phx-hook="GraphCamera"
        data-selected={to_string(@selected)}
        data-cw={@world.cw}
        data-ch={@world.ch}
        class="flex-1 min-w-0 min-h-0 relative overflow-hidden cursor-grab bg-(--k-paper) bg-[radial-gradient(var(--k-grid-dots)_1px,transparent_1px)] bg-size-[26px_26px]"
      >
        <div id="graph-world" class="absolute left-0 top-0 origin-top-left pointer-events-none">
          <svg
            width={@world.w}
            height={@world.h}
            class="absolute left-0 top-0 pointer-events-none overflow-visible"
          >
            <defs>
              <marker id="vw" markerWidth="7" markerHeight="7" refX="6" refY="3.5" orient="auto">
                <path d="M0 0 L7 3.5 L0 7 z" fill="#5B4B96" />
              </marker>
              <marker id="vr" markerWidth="7" markerHeight="7" refX="6" refY="3.5" orient="auto">
                <path d="M0 0 L7 3.5 L0 7 z" fill="#9C978A" />
              </marker>
            </defs>
            <g id="graph-edges" phx-update="stream">
              <path
                :for={{id, e} <- @streams.edges}
                id={id}
                data-edge={e.data}
                d={e.d}
                fill="none"
                stroke={if(e.kind == :writes, do: "#5B4B96", else: "#9C978A")}
                stroke-width={if(e.kind == :writes, do: "1.6", else: "1.4")}
                marker-end={if(e.kind == :writes, do: "url(#vw)", else: "url(#vr)")}
              />
            </g>
          </svg>
          <div id="graph-nodes" phx-update="stream">
            <.graph_node :for={{id, n} <- @streams.nodes} id={id} node={n} />
          </div>
        </div>
        <div
          :if={!@selected}
          id="graph-hint"
          class="absolute right-[16px] top-[14px] max-w-[210px] text-[12px] leading-[1.55] text-(--k-faint) text-right [text-wrap:pretty] pointer-events-none"
        >
          Click a node to inspect it. Drag the canvas to pan, ⌘-scroll to zoom.
        </div>
      </div>

      <div
        id="graph-strip"
        class="flex-none h-[30px] flex items-center gap-[14px] px-[12px] border-t border-(--k-line) bg-(--k-tint)"
      >
        <div class="flex items-center gap-px">
          <button
            id="graph-zoom-out"
            type="button"
            phx-click={JS.dispatch("graph:zoom", to: "#graph-canvas", detail: %{f: 1 / 1.2})}
            class="w-[20px] h-[20px] flex items-center justify-center text-(--k-dim) cursor-pointer"
          >
            <.icon name="ph-minus" class="text-[11px]" />
          </button>
          <span
            id="graph-zoom"
            phx-update="ignore"
            class="font-(family-name:--k-mono) text-[11.5px] text-(--k-body) px-[3px] w-[38px] text-center"
          >
            100%
          </span>
          <button
            id="graph-zoom-in"
            type="button"
            phx-click={JS.dispatch("graph:zoom", to: "#graph-canvas", detail: %{f: 1.2})}
            class="w-[20px] h-[20px] flex items-center justify-center text-(--k-dim) cursor-pointer"
          >
            <.icon name="ph-plus" class="text-[11px]" />
          </button>
          <button
            id="graph-fit"
            type="button"
            title="Fit"
            phx-click={JS.dispatch("graph:fit", to: "#graph-canvas")}
            class="w-[20px] h-[20px] flex items-center justify-center text-(--k-dim) cursor-pointer"
          >
            <.icon name="ph-crosshair" class="text-[11px]" />
          </button>
        </div>
        <div class="w-px h-[14px] bg-(--k-line)"></div>
        <div id="graph-legend" class="flex items-center gap-[14px]">
          <span class="flex items-center gap-[6px] text-[11px] text-(--k-dim)">
            <span class="w-[16px] h-0 border-t-[1.6px] border-solid border-(--k-violet)"></span>
            writes
          </span>
          <span class="flex items-center gap-[6px] text-[11px] text-(--k-dim)">
            <span class="w-[16px] h-0 border-t-[1.4px] border-solid border-[#9C978A]"></span> reads
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :node, :map, required: true

  defp graph_node(%{node: %{kind: :app}} = assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@node.path}
      data-selected={@node.selected}
      style={"left:#{@node.x}px; top:#{@node.y}px; width:#{@node.w}px; height:#{@node.h}px;"}
      class={[
        "absolute block rounded-[9px] bg-(--k-card) cursor-pointer overflow-hidden pointer-events-auto transition-shadow duration-150",
        if(@node.selected,
          do: "shadow-[0_0_0_1.5px_#5B4B96,0_0_0_5px_rgba(91,75,150,.11)]",
          else: "shadow-[0_0_0_1px_#DDDAD1,0_2px_8px_rgba(27,26,23,.06)]"
        )
      ]}
    >
      <div class="h-[29px] flex items-center gap-[8px] px-[10px] bg-(--k-tint) border-b border-(--k-line)">
        <span class="w-[6px] h-[6px] rounded-full bg-(--k-mint)"></span>
        <span class="font-(family-name:--k-mono) text-[12px] font-medium text-(--k-ink)">
          {@node.symbol}
        </span>
        <div class="flex-1"></div>
        <span :if={@node.route} class="font-(family-name:--k-mono) text-[10.5px] text-(--k-faint)">
          {@node.route}
        </span>
        <.icon name="ph-arrows-out-simple" class="text-[12px] text-(--k-faint)" />
      </div>
      <div :if={@node.body} class="p-[12px] flex flex-col gap-[7px]">
        <div
          :for={item <- elem(@node.body, 1)}
          class={[
            "h-[24px] rounded-[4px] border border-(--k-line) flex items-center px-[7px] text-[10.5px] text-[#9B968A]",
            elem(@node.body, 0) == :routes && "font-(family-name:--k-mono)"
          ]}
        >
          {item}
        </div>
      </div>
    </.link>
    """
  end

  defp graph_node(%{node: %{kind: :store}} = assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@node.path}
      data-selected={@node.selected}
      style={"left:#{@node.x}px; top:#{@node.y}px; width:#{@node.w}px; height:#{@node.h}px;"}
      class={[
        "absolute rounded-[8px] bg-(--k-card) cursor-pointer pointer-events-auto transition-shadow duration-150 py-[9px] px-[11px] flex flex-col gap-[4px]",
        if(@node.selected,
          do: "shadow-[0_0_0_1.5px_#5B4B96,0_0_0_5px_rgba(91,75,150,.11)]",
          else: "shadow-[0_0_0_1px_#DDDAD1]"
        )
      ]}
    >
      <div class="flex items-center gap-[7px]">
        <.icon
          name="ph-database"
          class={
            if(@node.selected,
              do: "text-[13px] text-(--k-violet)",
              else: "text-[13px] text-(--k-faint)"
            )
          }
        />
        <span class="font-(family-name:--k-mono) text-[12px] font-medium text-(--k-ink)">
          {@node.symbol}
        </span>
        <div class="flex-1"></div>
        <span data-rows class="text-[10.5px] text-(--k-dim) whitespace-nowrap">{@node.rows}</span>
      </div>
      <div class="font-(family-name:--k-mono) text-[10.5px] text-(--k-faint) whitespace-nowrap overflow-hidden text-ellipsis">
        {Enum.join(@node.fields, " · ")}
      </div>
    </.link>
    """
  end

  attr :title, :string, required: true
  attr :reasons, :list, required: true

  # The degraded stage, in the prototype's red callout (tracesStage's
  # "Invariant violated" box), in the listStage frame.
  defp degraded_stage(assigns) do
    ~H"""
    <div class="flex-1 min-w-0 overflow-y-auto px-[18px] py-[16px] flex flex-col gap-[8px] bg-(--k-paper)">
      <div
        id="graph-degraded"
        class="max-w-[620px] px-[13px] py-[11px] rounded-[9px] bg-(--k-red-chip) border border-(--k-red-chip-border) flex flex-col gap-[4px]"
      >
        <span class="text-[12.5px] font-semibold text-(--k-red-text)">{@title}</span>
        <span
          :for={r <- @reasons}
          data-reason
          class="font-(family-name:--k-mono) text-[12px] text-(--k-red-text)"
        >
          {r[:name]} [{r[:code]}] {r[:message]}
        </span>
      </div>
    </div>
    """
  end

  attr :panel, :map, required: true
  attr :universe, :string, required: true

  # panelFor() in the inspector frame: header, key/value rows, extra.
  defp inspector(assigns) do
    ~H"""
    <div id="inspector" class="contents">
      <div class="pt-[12px] px-[14px] pb-[11px] border-b border-(--k-line) flex items-start gap-[8px]">
        <div class="flex flex-col gap-[5px] min-w-0">
          <span class="text-[10.5px] tracking-[.11em] uppercase text-(--k-faint)">Selected</span>
          <span
            id="inspector-name"
            class="font-(family-name:--k-mono) text-[14px] font-medium break-all"
          >
            {@panel.name}
          </span>
          <span class="text-[12px] text-(--k-dim)">{@panel.sub}</span>
        </div>
        <div class="flex-1"></div>
        <.link
          id="inspector-close"
          patch={~p"/_/u/#{@universe}"}
          class="text-[14px] text-(--k-faint) cursor-pointer pt-[2px] flex"
        >
          <.icon name="ph-x" class="text-[14px]" />
        </.link>
      </div>
      <div class="px-[14px] py-[12px] flex flex-col gap-[9px]">
        <div :for={r <- @panel.rows} data-row={r.k} class="flex gap-[10px] text-[12.5px]">
          <span class="w-[76px] flex-none text-(--k-faint)">{r.k}</span>
          <span class={
            if(r.mono,
              do: "font-(family-name:--k-mono) text-[11.5px] text-(--k-body) min-w-0 break-words",
              else: "text-(--k-ink) min-w-0 break-words"
            )
          }>
            {r.v}
          </span>
        </div>
      </div>
      <div :if={@panel.kind == :store} class="px-[14px] pb-[14px]">
        <div class="flex flex-col gap-[8px] pt-[4px]">
          <div class="flex items-center">
            <span class="text-[10.5px] tracking-[.11em] uppercase text-(--k-faint)">Rows</span>
            <div class="flex-1"></div>
            <.link
              id="inspector-open-data"
              patch={@panel.data_path}
              class="text-[11.5px] text-(--k-violet) cursor-pointer font-medium"
            >
              Open in Data
            </.link>
          </div>
          <div
            :if={@panel.sample != []}
            id="inspector-rows"
            class="rounded-[8px] bg-(--k-card) border border-(--k-line) overflow-hidden"
          >
            <div
              :for={{first, middle, last} <- @panel.sample}
              data-sample-row
              class="flex items-baseline gap-[8px] px-[10px] py-[7px] border-t border-(--k-row-line-2) first:border-t-0"
            >
              <span class="text-[12px] font-medium w-[44px] flex-none overflow-hidden text-ellipsis whitespace-nowrap">
                {first}
              </span>
              <span class="text-[11.5px] text-(--k-faint) flex-1 overflow-hidden text-ellipsis whitespace-nowrap">
                {middle}
              </span>
              <span class="font-(family-name:--k-mono) text-[11.5px] text-(--k-body)">{last}</span>
            </div>
          </div>
          <span :if={@panel.more > 0} id="inspector-more" class="text-[11.5px] text-(--k-faint)">
            +{@panel.more} more · newest first
          </span>
        </div>
      </div>
    </div>
    """
  end
end
