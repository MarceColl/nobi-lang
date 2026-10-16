defmodule KinokoWeb.Console.UniverseLive do
  @moduledoc """
  `/_/u/:universe`: one universe's stages. `?view=graph` (the default) is
  the System graph, ported from the Kinoko Vellum prototype's
  `graphStage()`: its apps and stores laid out by
  `KinokoWeb.Console.GraphLayout`, joined by what they read and write,
  with `?sel=<symbol>` opening the inspector (`panelFor()`). The camera
  (pan, zoom, fit) is the `GraphCamera` hook's.

  `?view=code&sym=<symbol>` is `codeStage()`: the committed and staged
  symbols by namespace, one symbol's canonical text, and a staged patch's
  reasons. `?view=data&store=<model>&dep=<deployment>` is `dataStage()`
  without its query panel: a store's newest rows in the deployment's file.

  Refreshes on every commit once connected.
  """

  use KinokoWeb, :live_view

  import KinokoWeb.Console.Components

  alias Kinoko.{Data, Deployment, Universe}
  alias Kinoko.Exec.Show
  alias KinokoWeb.Console.{Cell, GraphLayout}

  # The inspector's rows sample, as the prototype's `EXPENSES.slice(0, 4)`.
  @sample 4

  # The Data stage's rows: the newest this many.
  @shown 200

  # How much of a staged patch's first reason its header chip shows.
  @chip_reason 48

  # The declaration keywords `codeStage()` colours, with a line's trailing `do`.
  @keyword_do ~r/^(defmodel|deftype|defapp|defroutes|deftest|def)( .* )(do)$/
  @keyword ~r/^(defmodel|deftype|defapp|defroutes|deftest|def)( .*)$/

  @impl true
  def mount(%{"universe" => universe}, _session, socket) do
    if known?(universe) do
      if connected?(socket), do: Universe.subscribe(universe)

      {:ok,
       socket
       |> assign(universe: universe, page_title: universe, view: :graph, sel: nil)
       |> stream_configure(:nodes, dom_id: & &1.id)
       |> stream_configure(:edges, dom_id: & &1.id)
       |> stream_configure(:symbols, dom_id: & &1.id)
       |> stream_configure(:lines, dom_id: & &1.id)
       |> stream_configure(:rows, dom_id: & &1.id)}
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
     |> assign(
       view: Map.get(@views, params["view"], :graph),
       sel: params["sel"],
       sym: params["sym"],
       store: params["store"],
       dep: params["dep"]
     )
     |> load()}
  end

  @impl true
  def handle_event("graph:deselect", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/_/u/#{socket.assigns.universe}")}

  def handle_event("data:switch", %{"data" => params}, socket) do
    query =
      [view: "data", store: params["store"]] ++
        if(params["dep"], do: [dep: params["dep"]], else: [])

    {:noreply, push_patch(socket, to: ~p"/_/u/#{socket.assigns.universe}?#{query}")}
  end

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

    case socket.assigns.view do
      :graph -> load_graph(socket, graph)
      :code -> load_code(socket, graph)
      :data -> load_data(socket, graph)
    end
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

  ## The Code stage (`codeStage()`)

  defp load_code(socket, graph) do
    %{universe: u, sym: sym} = socket.assigns
    entries = code_entries(u)

    if entries == [] do
      assign(socket, stage: :code_empty, panel: nil)
    else
      current = Enum.find(entries, hd(entries), &(&1.symbol == sym))

      text =
        case Universe.read(u, current.symbol) do
          {:ok, text} -> text
          _ -> ""
        end

      lines =
        text
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.map(fn {line, n} ->
          Map.put(keyword(line), :id, "line-#{n}") |> Map.put(:n, n)
        end)

      socket
      |> assign(
        stage: :code,
        panel: nil,
        code: %{
          symbol: current.symbol,
          count: socket.assigns.symbol_count,
          patch: current.patch,
          failing: failing(u, current),
          cid: current.cid,
          graph_path: graph_path(u, graph, current.symbol)
        }
      )
      |> stream(:symbols, symbol_items(entries, current.symbol, u), reset: true)
      |> stream(:lines, lines, reset: true)
    end
  end

  # Committed symbols, and those only a staged patch defines, by name; each
  # with the first patch (in `read/2`'s id order) that defines it.
  defp code_entries(u) do
    staged = listed(Universe.staged(u)) |> Enum.sort_by(& &1.id)

    patches =
      for p <- staged, s <- Map.get(p, :defines, []), reduce: %{} do
        acc -> Map.put_new(acc, s, p)
      end

    committed =
      for s <- listed(Universe.symbols(u)),
          do: %{symbol: s.symbol, cid: s.cid, signature: s.signature, patch: patches[s.symbol]}

    names = MapSet.new(committed, & &1.symbol)

    only_staged =
      for {s, p} <- patches,
          not MapSet.member?(names, s),
          do: %{symbol: s, cid: nil, signature: nil, patch: p}

    Enum.sort_by(committed ++ only_staged, &{group(&1.symbol), &1.symbol})
  end

  defp group(symbol), do: symbol |> String.split(".", parts: 2) |> hd()

  defp symbol_items(entries, current, u) do
    entries
    |> Enum.chunk_by(&group(&1.symbol))
    |> Enum.flat_map(fn [first | _] = chunk ->
      g = group(first.symbol)

      [%{id: "symgroup-" <> sanitize(g), kind: :group, label: g}] ++
        for e <- chunk do
          %{
            id: "sym-" <> sanitize(e.symbol),
            kind: :symbol,
            symbol: e.symbol,
            name: if(e.symbol == g, do: g, else: String.replace_prefix(e.symbol, g <> ".", "")),
            icon: symbol_icon(e.signature),
            patch: e.patch && e.patch.id,
            selected: e.symbol == current,
            path: ~p"/_/u/#{u}?#{[view: "code", sym: e.symbol]}"
          }
        end
    end)
  end

  defp symbol_icon("model" <> _), do: :cube
  defp symbol_icon("type " <> _), do: :cube
  defp symbol_icon("app"), do: :app
  defp symbol_icon(_), do: :function

  # A source line split as the prototype's `[keyword, rest, "do"]`.
  defp keyword(line) do
    case Regex.run(@keyword_do, line) || Regex.run(@keyword, line) do
      [_, kw, rest, d] -> %{kw: kw, rest: rest, do: d}
      [_, kw, rest] -> %{kw: kw, rest: rest, do: nil}
      nil -> %{kw: nil, rest: line, do: nil}
    end
  end

  # The health reasons naming `entry`, when the universe is degraded.
  defp failing(u, %{patch: nil, cid: cid} = entry) when is_binary(cid) do
    case Universe.health(u) do
      {:degraded, reasons} -> Enum.filter(reasons, &(&1[:name] == entry.symbol))
      _ -> []
    end
  end

  defp failing(_u, _entry), do: []

  defp graph_path(u, %{apps: apps, stores: stores}, symbol) do
    if Enum.any?(apps ++ stores, &(&1.symbol == symbol)),
      do: ~p"/_/u/#{u}?#{[view: "graph", sel: symbol]}",
      else: ~p"/_/u/#{u}"
  end

  defp graph_path(u, _graph, _symbol), do: ~p"/_/u/#{u}"

  defp sanitize(s), do: String.replace(s, ~r/[^A-Za-z0-9_-]/, "-")

  defp chip_reason(%{reasons: [%{message: m} | _]}) do
    if String.length(m) > @chip_reason,
      do: "staged · " <> String.slice(m, 0, @chip_reason) <> "…",
      else: "staged · " <> m
  end

  defp chip_reason(_patch), do: "staged"

  ## The Data stage (`dataStage()`)

  defp load_data(socket, graph) do
    %{universe: u, head: head} = socket.assigns
    deployments = Enum.filter(Deployment.list(), &(&1.universe == u))

    cond do
      deployments == [] -> assign(socket, stage: :data_empty, panel: nil)
      head == 0 -> assign(socket, stage: :empty, panel: nil)
      true -> load_store(socket, graph, deployments)
    end
  end

  defp load_store(socket, %{stores: stores} = graph, deployments) do
    %{universe: u, store: store_param, dep: dep_param} = socket.assigns
    dep = Enum.find(deployments, hd(deployments), &(&1.name == dep_param))
    counts = rows(dep)
    store = Enum.find(stores, List.first(stores), &(&1.symbol == store_param))

    {columns, rows, n} =
      case {store, Universe.models(u)} do
        {%{symbol: model}, {:ok, models}} ->
          fields = Map.get(models, model, [])
          {id, rest} = Enum.split_with(fields, &(elem(&1, 0) == "id"))
          columns = for {f, type, _} <- id ++ rest, do: %{name: f, numeric: Cell.numeric?(type)}
          n = Map.get(counts, model, 0)
          {columns, data_rows(dep, model, models, columns, n), n}

        _ ->
          {[], [], 0}
      end

    written_by =
      case store && for(%{to: t, kind: :writes, from: f} <- graph.edges, t == store.symbol, do: f) do
        [_ | _] = apps -> Enum.join(apps, ", ")
        _ -> "none"
      end

    footer =
      Enum.join(
        [count(n, "row")] ++
          if(n > @shown, do: ["showing #{@shown}"], else: []) ++
          ["written by " <> written_by],
        " · "
      )

    socket
    |> assign(
      stage: :data,
      panel: nil,
      data: %{
        store: store && store.symbol,
        rows: n,
        stores:
          for(
            s <- stores,
            do: {"#{s.symbol}  ·  #{count(Map.get(counts, s.symbol, 0), "row")}", s.symbol}
          ),
        deployments: if(length(deployments) > 1, do: Enum.map(deployments, & &1.name), else: []),
        deployment: dep.name,
        columns: columns,
        footer: footer,
        form:
          to_form(
            %{"store" => store && store.symbol, "dep" => dep.name},
            as: :data
          )
      }
    )
    |> stream(:rows, rows, reset: true)
  end

  defp load_store(socket, graph, _deployments), do: load_graph(socket, graph)

  # The newest `@shown` rows of `model`, read only when the file has some,
  # so a view never creates a data file.
  defp data_rows(dep, model, models, columns, n) when n > 0 do
    with {:ok, repo} <- Data.open(dep.name),
         {:ok, list} <- Data.list(repo, model, models, order: :desc, limit: @shown) do
      for {{:rec, _, values}, i} <- Enum.with_index(list) do
        %{
          id: row_id(values["id"], i),
          zebra: rem(i, 2) == 1,
          cells: for(c <- columns, do: {c, Cell.text(values[c.name], models)})
        }
      end
    else
      _ -> []
    end
  end

  defp data_rows(_dep, _model, _models, _columns, _n), do: []

  defp row_id({:uuid, id}, _i), do: "row-" <> id
  defp row_id(_, i), do: "row-#{i}"

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

    with {:ok, models} <- Universe.models(u),
         fields when is_list(fields) <- Map.get(models, model) do
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
    with {:ok, models} <- Universe.models(u),
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

  defp heading(%{view: :data, stage: :data, data: %{store: store, rows: n}})
       when is_binary(store),
       do: {"Data", "#{store} · #{count(n, "row")}"}

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
          <.list_empty
            id={if(@view == :graph, do: "graph-empty", else: "data-uncommitted")}
            title="Nothing committed"
            body="Stage a patch through the MCP or the REPL below."
          />
        <% :code_empty -> %>
          <.list_empty
            id="code-empty"
            title="Nothing committed"
            body="Stage a patch through the MCP or the REPL below."
          />
        <% :code -> %>
          <.code_stage streams={@streams} code={@code} />
        <% :data_empty -> %>
          <.list_empty
            id="data-empty"
            title="No data yet"
            body="Rows live in a deployment. Serve this universe to start storing."
          />
        <% :data -> %>
          <.data_stage streams={@streams} data={@data} />
        <% {:degraded, reasons} -> %>
          <.degraded_stage title="Committed code no longer typechecks" reasons={reasons} />
        <% {:error, text} -> %>
          <.degraded_stage title={text} reasons={[]} />
      <% end %>
      <:inspector :if={@panel}>
        <.inspector panel={@panel} universe={@universe} />
      </:inspector>
    </.shell>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  # listStage()'s empty state (IMPLEMENTATION-MAP §3 copy).
  defp list_empty(assigns) do
    ~H"""
    <div class="flex-1 min-w-0 overflow-y-auto px-[18px] py-[16px] flex flex-col gap-[8px] bg-(--k-paper)">
      <div id={@id} class="max-w-[420px] flex flex-col gap-[9px] pt-[50px]">
        <span class="font-(family-name:--k-display) text-[18px] font-medium">{@title}</span>
        <span class="text-[13px] leading-[1.6] text-(--k-dim) [text-wrap:pretty]">{@body}</span>
      </div>
    </div>
    """
  end

  attr :streams, :any, required: true
  attr :code, :map, required: true

  # codeStage(): the symbols panel, then the header, source and footer.
  defp code_stage(assigns) do
    ~H"""
    <div class="flex-1 min-w-0 flex">
      <div
        id="symbols"
        class="w-[212px] flex-none border-r border-(--k-line) bg-(--k-tint) flex flex-col overflow-y-auto"
      >
        <div class="pt-[12px] px-[13px] pb-[8px] flex items-center">
          <span class="text-[10.5px] tracking-[.11em] uppercase text-(--k-faint)">Symbols</span>
          <div class="flex-1"></div>
          <span id="symbols-count" class="text-[11px] text-(--k-faint)">{@code.count}</span>
        </div>
        <div
          id="symbols-list"
          phx-update="stream"
          class="px-[8px] pb-[10px] flex flex-col gap-px"
        >
          <.symbol_item :for={{id, item} <- @streams.symbols} id={id} item={item} />
        </div>
      </div>

      <div class="flex-1 min-w-0 flex flex-col bg-(--k-card)">
        <div
          id="code-header"
          class="h-[36px] flex-none flex items-center gap-[11px] px-[14px] border-b border-(--k-line) bg-(--k-tint)"
        >
          <span id="code-symbol" class="font-(family-name:--k-mono) text-[12.5px] font-medium">
            {@code.symbol}
          </span>
          <span
            :if={@code.patch}
            id="code-chip"
            class="text-[11px] text-(--k-amber) bg-(--k-amber-chip) border border-(--k-amber-chip-border) px-[7px] py-[1.5px] rounded-[4px] whitespace-nowrap overflow-hidden text-ellipsis min-w-0"
          >
            {chip_reason(@code.patch)}
          </span>
          <span
            :if={!@code.patch and @code.failing == []}
            id="code-chip"
            class="text-[11px] text-(--k-mint) bg-(--k-mint-chip) border border-(--k-mint-chip-border) px-[7px] py-[1.5px] rounded-[4px]"
          >
            typechecks
          </span>
          <div class="flex-1"></div>
          <span
            :if={@code.cid}
            id="code-cid"
            class="font-(family-name:--k-mono) text-[11px] text-(--k-faint) whitespace-nowrap"
          >
            sha256 {String.slice(@code.cid, 0, 8)}
          </span>
        </div>
        <div
          id="source"
          class="flex-1 min-h-0 overflow-y-auto py-[14px] font-(family-name:--k-mono) text-[12.5px] leading-[1.75]"
        >
          <div id="source-lines" phx-update="stream">
            <div :for={{id, l} <- @streams.lines} id={id} class="flex">
              <span
                data-n
                class="w-[44px] flex-none text-right pr-[14px] text-(--k-gutter) select-none"
              >
                {l.n}
              </span>
              <span class="whitespace-pre" phx-no-format><span :if={l.kw} data-kw class="text-(--k-violet)">{l.kw}</span>{l.rest}<span :if={l.do} class="text-(--k-violet)">{l.do}</span></span>
            </div>
          </div>
          <.reasons_callout
            :if={@code.patch}
            id="staged-reasons"
            title={"#{@code.patch.id} cannot promote"}
            reasons={@code.patch.reasons}
          />
          <.reasons_callout
            :if={@code.failing != []}
            id="code-failing"
            title="Committed code no longer typechecks"
            reasons={@code.failing}
          />
        </div>
        <div class="flex-none border-t border-(--k-line) bg-(--k-tint) px-[14px] py-[10px] flex items-center gap-[12px]">
          <span class="text-[12px] text-(--k-dim)">
            Every symbol is content-addressed; a body edit with the same signature invalidates nothing.
          </span>
          <div class="flex-1"></div>
          <.link
            id="code-show-graph"
            patch={@code.graph_path}
            class="flex-none whitespace-nowrap h-[26px] px-[10px] rounded-[6px] border border-(--k-line) bg-(--k-card) text-(--k-body) text-[12px] cursor-pointer flex items-center"
          >
            Show on the graph
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true

  defp symbol_item(%{item: %{kind: :group}} = assigns) do
    ~H"""
    <div
      id={@id}
      class="px-[8px] py-[5px] text-[11px] tracking-[.06em] uppercase text-(--k-faint)"
    >
      {@item.label}
    </div>
    """
  end

  defp symbol_item(assigns) do
    assigns =
      assign(
        assigns,
        :icon_class,
        cond do
          assigns.item.patch -> "text-[13px] text-(--k-amber)"
          assigns.item.selected -> "text-[13px] text-(--k-violet)"
          true -> "text-[13px] text-(--k-faint)"
        end
      )

    ~H"""
    <.link
      id={@id}
      patch={@item.path}
      data-selected={@item.selected}
      class={[
        "flex items-center gap-[8px] px-[8px] py-[5px] rounded-[6px] cursor-pointer",
        if(@item.selected,
          do: "bg-(--k-card) shadow-[inset_2px_0_0_#5B4B96,0_1px_2px_rgba(27,26,23,.05)]",
          else: "bg-transparent"
        )
      ]}
    >
      <%= case @item.icon do %>
        <% :cube -> %>
          <.icon name="ph-cube" class={@icon_class} />
        <% :app -> %>
          <.icon name="ph-app-window" class={@icon_class} />
        <% :function -> %>
          <.icon name="ph-function" class={@icon_class} />
      <% end %>
      <span class={[
        "font-(family-name:--k-mono) text-[11.5px] min-w-0 overflow-hidden text-ellipsis whitespace-nowrap",
        if(@item.selected, do: "text-(--k-ink)", else: "text-(--k-body)")
      ]}>
        {@item.name}
      </span>
      <div class="flex-1"></div>
      <span
        :if={@item.patch}
        data-staged
        class="flex-none text-[10px] text-(--k-amber) tracking-[.04em] whitespace-nowrap"
      >
        STAGED {@item.patch}
      </span>
      <span
        :if={!@item.patch}
        data-committed
        class="flex-none w-[6px] h-[6px] rounded-full bg-(--k-mint)"
      >
      </span>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :reasons, :list, required: true

  # tracesStage()'s red "Invariant violated" callout, below the source.
  defp reasons_callout(assigns) do
    ~H"""
    <div class="px-[14px] pt-[14px] font-(family-name:--k-sans) leading-[normal]">
      <div
        id={@id}
        class="px-[13px] py-[11px] rounded-[9px] bg-(--k-red-chip) border border-(--k-red-chip-border) flex flex-col gap-[4px]"
      >
        <span class="text-[12.5px] font-semibold text-(--k-red-text)">{@title}</span>
        <span
          :for={r <- @reasons}
          data-reason
          class="font-(family-name:--k-mono) text-[12px] text-(--k-red-text) break-words"
        >
          {r[:name]} [{r[:code]}] {r[:message]}
        </span>
      </div>
    </div>
    """
  end

  attr :streams, :any, required: true
  attr :data, :map, required: true

  # dataStage() without "Insert a row" and the Query panel: the store
  # (and deployment) selects, the column header, the rows, the footer row.
  defp data_stage(assigns) do
    ~H"""
    <div id="data" class="flex-1 min-w-0 flex flex-col bg-(--k-card)">
      <.form
        for={@data.form}
        id="data-form"
        phx-change="data:switch"
        class="flex-none flex items-center gap-[10px] px-[14px] py-[8px] border-b border-(--k-line) bg-(--k-tint)"
      >
        <div :if={@data.stores != []} class="relative flex-none flex items-center">
          <select
            id="data-store"
            name={@data.form[:store].name}
            class="appearance-none h-[29px] pl-[11px] pr-[30px] rounded-[6px] border border-(--k-line) bg-(--k-card) text-(--k-ink) font-(family-name:--k-mono) text-[12px] cursor-pointer"
          >
            {Phoenix.HTML.Form.options_for_select(@data.stores, @data.form[:store].value)}
          </select>
          <.icon
            name="ph-caret-down"
            class="absolute right-[10px] text-[11px] text-(--k-faint) pointer-events-none"
          />
        </div>
        <div :if={@data.deployments != []} class="relative flex-none flex items-center">
          <select
            id="data-dep"
            name={@data.form[:dep].name}
            class="appearance-none h-[29px] pl-[11px] pr-[30px] rounded-[6px] border border-(--k-line) bg-(--k-card) text-(--k-ink) font-(family-name:--k-mono) text-[12px] cursor-pointer"
          >
            {Phoenix.HTML.Form.options_for_select(@data.deployments, @data.form[:dep].value)}
          </select>
          <.icon
            name="ph-caret-down"
            class="absolute right-[10px] text-[11px] text-(--k-faint) pointer-events-none"
          />
        </div>
        <div class="flex-1 min-w-[8px]"></div>
        <span id="data-note" class="flex-none text-[11.5px] text-(--k-faint) whitespace-nowrap">
          deployment {@data.deployment}
        </span>
      </.form>
      <div
        :if={@data.store}
        id="data-cols"
        class="flex-none flex border-b border-(--k-line) bg-(--k-tint)"
      >
        <span
          :for={c <- @data.columns}
          data-col={c.name}
          class={[
            "py-[9px] px-[18px] font-(family-name:--k-mono) text-[11.5px] text-(--k-dim) min-w-0",
            col_flex(c),
            if(c.numeric, do: "text-right", else: "text-left")
          ]}
        >
          {c.name}
        </span>
      </div>
      <div :if={@data.store} id="data-table" class="flex-1 min-h-0 overflow-y-auto">
        <div id="data-rows" phx-update="stream">
          <div
            :for={{id, r} <- @streams.rows}
            id={id}
            data-row
            class={[
              "flex border-b border-(--k-row-line)",
              if(r.zebra, do: "bg-(--k-zebra)", else: "bg-(--k-card)")
            ]}
          >
            <span
              :for={{c, text} <- r.cells}
              data-cell={c.name}
              class={[
                "py-[9px] px-[18px] min-w-0 overflow-hidden text-ellipsis whitespace-nowrap",
                col_flex(c),
                cell_class(c)
              ]}
            >
              {text}
            </span>
          </div>
        </div>
        <div class="flex border-b border-(--k-line) bg-(--k-tint)">
          <span id="data-footer" class="flex-[6] py-[9px] px-[18px] text-[12px] text-(--k-dim)">
            {@data.footer}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # The prototype's column weights: `id` and Int columns 1, text 2.
  defp col_flex(%{name: "id"}), do: "flex-1"
  defp col_flex(%{numeric: true}), do: "flex-1"
  defp col_flex(_), do: "flex-[2]"

  defp cell_class(%{name: "id"}),
    do: "font-(family-name:--k-mono) text-[12px] text-(--k-faint) text-left"

  defp cell_class(%{numeric: true}),
    do: "font-(family-name:--k-mono) text-[12px] text-(--k-ink) text-right"

  defp cell_class(_), do: "text-[12.5px] text-(--k-ink) text-left"

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
        <div
          id="graph-world"
          phx-mounted={JS.ignore_attributes(["style"])}
          class="absolute left-0 top-0 origin-top-left pointer-events-none"
        >
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
          class="h-[24px] rounded-[4px] border border-(--k-line) flex items-center px-[7px] text-[10.5px] text-[#9B968A]"
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
        class="px-[13px] py-[11px] rounded-[9px] bg-(--k-red-chip) border border-(--k-red-chip-border) flex flex-col gap-[4px]"
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
