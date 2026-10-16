defmodule KinokoWeb.Console.GraphLayout do
  @moduledoc """
  The System graph's geometry, worked out on the server from
  `Kinoko.Universe.graph/1` with the Kinoko Vellum prototype's numbers
  (`graphStage()`): pure and deterministic, so the same graph always
  draws the same picture.

  ## Nodes

  App cards are 264 wide, at left 38, stacked from top 30 with 58 between
  them. A card is its 29px header plus, when there is anything to show, a
  body of up to three 24px boxes (12px padding, 7px apart): the fields of
  the first store the app writes (`id` left out), else its routes.

  Stores sit in a row 58 below the last app (at top 30 when there is no
  app), 68 apart and 52 tall, from left 38. A store is 196 wide for a name
  of 11 characters or fewer and 9 wider per character after that, which
  gives the prototype's 214 for `Split.Expense` and 196 for `Split.Share`.

  ## Edges

  Every edge joins an app and a store. A write points at the store and a
  read at the app; both take the same route, reversed. Each store spreads
  its edges evenly over its top side, so no two edges share an end.

  * From the last app (the one directly above the store row): a straight
    `V` when the store's port lies under the card, as the prototype's
    Split → Expense edges; otherwise the prototype's `C` curve from the
    card's bottom to the port. The curve's control points lie between the
    card's bottom and the row's top, so it never leaves that band.
  * From any app higher up: out of the card's right side, `H` to a lane
    right of the app column, `V` down into the band between the last app
    and the store row, `H` over to the port and `V` down to it. Lower
    apps take the inner lanes and the shallower bands, so a lane's exit
    never crosses another lane.

  Nothing but the store row lies below the last app, and nothing but app
  cards lies in the column, so no segment passes through a node box. The
  band grows past 58 only when there are more lanes than fit.

  `cw`/`ch` are the content extent the camera fits (the prototype's
  `cw`/`ch`); `w`/`h` the world, oversized as the prototype's is so there
  is room to pan.
  """

  @left 38
  @top 30
  @app_w 264
  @gap 58
  @store_gap 68
  @store_h 52
  @header 29
  @box 24
  @box_gap 7
  @pad 12
  @body_max 3
  # the lanes right of the app column, and the bands under the last app
  @lane_off 18
  @lane_step 10
  @band_off 12
  @band_step 8
  # where the prototype's curve leaves the app card (256 = 302 - 46)
  @curve_off 46
  @curve_step 14
  @margin 12

  @type point :: {number(), number()}
  @type segment :: {:v, number()} | {:h, number()} | {:c, point(), point(), point()}
  @type graph_node :: %{
          id: String.t(),
          symbol: String.t(),
          kind: :app | :store,
          x: integer(),
          y: integer(),
          w: integer(),
          h: integer(),
          route: String.t() | nil,
          body: {:fields | :routes, [String.t()]} | nil,
          fields: [String.t()]
        }
  @type edge :: %{
          id: String.t(),
          data: String.t(),
          from: String.t(),
          to: String.t(),
          kind: :reads | :writes,
          start: point(),
          segments: [segment()],
          d: String.t()
        }
  @type t :: %{
          nodes: [graph_node()],
          edges: [edge()],
          cw: integer(),
          ch: integer(),
          w: integer(),
          h: integer()
        }

  @doc "The layout of `graph` (`Kinoko.Universe.graph/1`'s map); see the moduledoc."
  @spec layout(map()) :: t()
  def layout(%{apps: apps, stores: stores, edges: edges}) do
    fields = Map.new(stores, &{&1.symbol, &1.fields})
    apps = place_apps(apps, edges, fields)
    last = List.last(apps)
    by_app = Map.new(apps, &{&1.symbol, &1})

    # Lane edges: from an app above the last one, lower apps first.
    lane_edges =
      edges
      |> Enum.filter(&(Map.has_key?(by_app, &1.from) and &1.from != (last && last.symbol)))
      |> Enum.sort_by(&{-index(apps, &1.from), &1.to, &1.kind})

    lanes = lane_edges |> Enum.with_index() |> Map.new()
    last_bottom = if last, do: last.y + last.h, else: nil

    store_top =
      if last,
        do: last_bottom + max(@gap, @band_off + length(lane_edges) * @band_step + @band_off),
        else: @top

    stores = place_stores(stores, store_top)
    by_store = Map.new(stores, &{&1.symbol, &1})
    ports = ports(edges, apps, by_store)

    curved =
      if last do
        edges
        |> Enum.filter(&(&1.from == last.symbol and not under?(last, ports[&1])))
        |> Enum.with_index()
        |> Map.new()
      else
        %{}
      end

    routed =
      for e <- edges,
          app = by_app[e.from],
          store = by_store[e.to],
          app != nil and store != nil do
        geometry = %{
          app: app,
          store: store,
          port: ports[e],
          last?: app == last,
          lane: lanes[e],
          exit: exit_y(app, e, lane_edges),
          band: last_bottom,
          curve: curved[e],
          column_right: @left + @app_w
        }

        route(e, geometry)
      end

    nodes = apps ++ stores
    {cw, ch} = extent(nodes, routed)
    %{nodes: nodes, edges: routed, cw: cw, ch: ch, w: cw + 340, h: ch + 330}
  end

  @doc "A node's DOM id: `node-` and the symbol, anything but `[A-Za-z0-9_-]` as `-`."
  @spec dom_id(String.t()) :: String.t()
  def dom_id(symbol), do: "node-" <> sanitize(symbol)

  @doc """
  Points along `edge`: every corner of its segments, and its curve
  sampled, for checking it against the node boxes.
  """
  @spec points(edge(), pos_integer()) :: [point()]
  def points(%{start: start, segments: segments}, steps \\ 24) do
    {_, acc} =
      Enum.reduce(segments, {start, [start]}, fn
        {:v, y}, {{x, y0}, acc} -> {{x, y}, line({x, y0}, {x, y}, steps) ++ acc}
        {:h, x}, {{x0, y}, acc} -> {{x, y}, line({x0, y}, {x, y}, steps) ++ acc}
        {:c, c1, c2, p}, {p0, acc} -> {p, bezier(p0, c1, c2, p, steps) ++ acc}
      end)

    Enum.reverse(acc)
  end

  ## Nodes

  defp place_apps(apps, edges, fields) do
    {placed, _} =
      Enum.map_reduce(apps, @top, fn app, top ->
        body = body(app, edges, fields)
        h = @header + body_height(body)

        node = %{
          id: dom_id(app.symbol),
          symbol: app.symbol,
          kind: :app,
          x: @left,
          y: top,
          w: @app_w,
          h: h,
          route: List.first(app.routes),
          body: body,
          fields: []
        }

        {node, top + h + @gap}
      end)

    placed
  end

  # The fields of the first store the app writes (`id` left out), else
  # its routes; nil when it has neither.
  defp body(app, edges, fields) do
    written =
      for %{from: from, to: to, kind: :writes} <- edges, from == app.symbol, do: to

    previewed =
      case written do
        [store | _] -> fields |> Map.get(store, []) |> Enum.reject(&(&1 == "id"))
        [] -> []
      end

    cond do
      previewed != [] -> {:fields, Enum.take(previewed, @body_max)}
      app.routes != [] -> {:routes, Enum.take(app.routes, @body_max)}
      true -> nil
    end
  end

  defp body_height(nil), do: 0

  defp body_height({_, items}) do
    n = length(items)
    2 * @pad + n * @box + (n - 1) * @box_gap
  end

  defp place_stores(stores, top) do
    {placed, _} =
      Enum.map_reduce(stores, @left, fn store, left ->
        w = store_width(store.symbol)

        node = %{
          id: dom_id(store.symbol),
          symbol: store.symbol,
          kind: :store,
          x: left,
          y: top,
          w: w,
          h: @store_h,
          route: nil,
          body: nil,
          fields: store.fields
        }

        {node, left + w + @store_gap}
      end)

    placed
  end

  defp store_width(symbol), do: 196 + max(0, String.length(symbol) - 11) * 9

  ## Edges

  # Each store's edges spread evenly over its top side, by app order,
  # writes first (the prototype's write sits left of its read).
  defp ports(edges, apps, by_store) do
    edges
    |> Enum.filter(&Map.has_key?(by_store, &1.to))
    |> Enum.group_by(& &1.to)
    |> Enum.flat_map(fn {to, group} ->
      s = by_store[to]
      sorted = Enum.sort_by(group, &{index(apps, &1.from), &1.kind != :writes})
      m = length(sorted)

      for {e, k} <- Enum.with_index(sorted, 1),
          do: {e, s.x + round(s.w * k / (m + 1))}
    end)
    |> Map.new()
  end

  defp under?(app, px), do: px >= app.x + @pad and px <= app.x + app.w - @pad

  # Where an edge leaves (or reaches) its app's right side: 15 down from
  # the top, 9 apart per edge, kept clear of the card's bottom.
  defp exit_y(app, e, lane_edges) do
    k =
      lane_edges
      |> Enum.filter(&(&1.from == app.symbol))
      |> Enum.find_index(&(&1 == e))

    if k, do: min(app.y + 15 + k * 9, app.y + app.h - 4)
  end

  defp route(e, g) do
    {start, segments} = forward(g)

    {start, segments} =
      case e.kind do
        :writes -> {start, segments}
        :reads -> reverse(start, segments)
      end

    %{
      id: "edge-" <> sanitize("#{e.from}--#{e.to}--#{e.kind}"),
      data: "#{e.from}->#{e.to}:#{e.kind}",
      from: e.from,
      to: e.to,
      kind: e.kind,
      start: start,
      segments: segments,
      d: path(start, segments)
    }
  end

  # The app → store route.
  defp forward(%{last?: true, curve: nil} = g) do
    {{g.port, g.app.y + g.app.h}, [{:v, g.store.y}]}
  end

  defp forward(%{last?: true} = g) do
    app = g.app
    sx = curve_start(app, g.port, g.curve)
    y0 = app.y + app.h
    {x1, y1} = {g.port, g.store.y}
    dx = x1 - sx
    dy = y1 - y0
    c1 = {round(sx + dx * 0.29), round(y0 + dy * 0.52)}
    c2 = {round(sx + dx * 0.71), round(y0 + dy * 0.83)}
    {{sx, y0}, [{:c, c1, c2, {x1, y1}}]}
  end

  defp forward(g) do
    lane_x = g.column_right + @lane_off + g.lane * @lane_step
    band_y = g.band + @band_off + g.lane * @band_step

    {{g.app.x + g.app.w, g.exit}, [{:h, lane_x}, {:v, band_y}, {:h, g.port}, {:v, g.store.y}]}
  end

  # A port right of the card: from 46 left of its right edge, 14 apart;
  # a port left of it: from the card's nearest point.
  defp curve_start(app, px, k) do
    if px > app.x + app.w - @pad,
      do: max(app.x + app.w - @curve_off - k * @curve_step, app.x + @pad),
      else: app.x + @pad
  end

  defp reverse(start, segments) do
    corners =
      Enum.scan(segments, start, fn
        {:v, y}, {x, _} -> {x, y}
        {:h, x}, {_, y} -> {x, y}
        {:c, _, _, p}, _ -> p
      end)

    [last | _] = Enum.reverse(corners)
    froms = [start | corners] |> Enum.drop(-1) |> Enum.reverse()

    reversed =
      segments
      |> Enum.reverse()
      |> Enum.zip(froms)
      |> Enum.map(fn
        {{:v, _}, {_, y}} -> {:v, y}
        {{:h, _}, {x, _}} -> {:h, x}
        {{:c, c1, c2, _}, p} -> {:c, c2, c1, p}
      end)

    {last, reversed}
  end

  defp path({x, y}, segments) do
    Enum.join(
      ["M#{x} #{y}"] ++
        Enum.map(segments, fn
          {:v, y} -> "V#{y}"
          {:h, x} -> "H#{x}"
          {:c, {ax, ay}, {bx, by}, {px, py}} -> "C#{ax} #{ay}, #{bx} #{by}, #{px} #{py}"
        end),
      " "
    )
  end

  defp extent(nodes, edges) do
    xs = for(n <- nodes, do: n.x + n.w) ++ for(e <- edges, {x, _} <- points(e, 1), do: x)
    ys = for(n <- nodes, do: n.y + n.h) ++ for(e <- edges, {_, y} <- points(e, 1), do: y)
    {Enum.max(xs, fn -> 0 end) + @margin, Enum.max(ys, fn -> 0 end) + @margin}
  end

  defp index(apps, symbol), do: Enum.find_index(apps, &(&1.symbol == symbol))

  defp sanitize(s), do: String.replace(s, ~r/[^A-Za-z0-9_-]/, "-")

  defp line({x0, y0}, {x1, y1}, steps),
    do: for(i <- steps..1//-1, do: {x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps})

  defp bezier({x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}, steps) do
    for i <- steps..1//-1 do
      t = i / steps
      u = 1 - t

      {u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3,
       u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3}
    end
  end
end
