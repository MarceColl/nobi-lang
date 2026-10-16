defmodule KinokoWeb.Console.GraphLayoutTest do
  @moduledoc """
  The System graph's server-side layout: app cards in a left column, the
  stores in a row below them, and edges routed in orthogonal segments
  (plus the prototype's one `C` curve) that never cross a node box.
  """
  use ExUnit.Case, async: true

  alias KinokoWeb.Console.GraphLayout

  @forum %{
    apps: [
      %{symbol: "Forum.Post", routes: ["/post/:id"]},
      %{symbol: "Forum.Settings", routes: ["/settings"]},
      %{symbol: "Forum.Threads", routes: ["/"]}
    ],
    stores: [
      %{symbol: "Forum.Reply", fields: ["id", "topic", "body"]},
      %{symbol: "Forum.Topic", fields: ["id", "title", "replies"]}
    ],
    edges: [
      %{from: "Forum.Post", to: "Forum.Reply", kind: :reads},
      %{from: "Forum.Post", to: "Forum.Reply", kind: :writes},
      %{from: "Forum.Post", to: "Forum.Topic", kind: :reads},
      %{from: "Forum.Post", to: "Forum.Topic", kind: :writes},
      %{from: "Forum.Threads", to: "Forum.Topic", kind: :reads},
      %{from: "Forum.Threads", to: "Forum.Topic", kind: :writes}
    ]
  }

  # The prototype's own diagram: Split writes and reads Split.Expense,
  # and writes Split.Share.
  @split %{
    apps: [%{symbol: "Split", routes: ["/split"]}],
    stores: [
      %{symbol: "Split.Expense", fields: ["id", "payer", "what", "cents"]},
      %{symbol: "Split.Share", fields: ["id", "who", "owes"]}
    ],
    edges: [
      %{from: "Split", to: "Split.Expense", kind: :reads},
      %{from: "Split", to: "Split.Expense", kind: :writes},
      %{from: "Split", to: "Split.Share", kind: :writes}
    ]
  }

  defp node(layout, symbol), do: Enum.find(layout.nodes, &(&1.symbol == symbol))

  defp edge(layout, from, to, kind),
    do: Enum.find(layout.edges, &(&1.data == "#{from}->#{to}:#{kind}"))

  test "apps stack at left 38 from top 30, 58 apart, 264 wide" do
    l = GraphLayout.layout(@forum)

    [post, settings, threads] =
      for s <- ~w(Forum.Post Forum.Settings Forum.Threads), do: node(l, s)

    assert {post.x, post.y, post.w} == {38, 30, 264}
    assert {settings.x, settings.y} == {38, post.y + post.h + 58}
    assert {threads.x, threads.y} == {38, settings.y + settings.h + 58}
  end

  test "stores sit in a row 58 below the last app, 68 apart, widths from the name (min 196)" do
    l = GraphLayout.layout(@split)
    split = node(l, "Split")
    expense = node(l, "Split.Expense")
    share = node(l, "Split.Share")

    assert expense.y == split.y + split.h + 58
    assert {expense.x, expense.w, expense.h} == {38, 214, 52}
    assert {share.x, share.y, share.w} == {38 + 214 + 68, expense.y, 196}
  end

  test "a writer's card previews up to 3 fields of the store it writes; others list routes" do
    l = GraphLayout.layout(@forum)
    assert node(l, "Forum.Post").body == {:fields, ["topic", "body"]}
    assert node(l, "Forum.Settings").body == {:routes, ["/settings"]}
    assert node(l, "Forum.Post").route == "/post/:id"
    # header 29, then 12px padding around 24px boxes 7 apart
    assert node(l, "Forum.Post").h == 29 + 24 + 2 * 24 + 7
  end

  test "the prototype's diagram: straight verticals under the app, a curve to the store beside it" do
    l = GraphLayout.layout(@split)
    split = node(l, "Split")
    expense = node(l, "Split.Expense")

    writes = edge(l, "Split", "Split.Expense", :writes)
    reads = edge(l, "Split", "Split.Expense", :reads)
    assert writes.d =~ ~r/^M\d+ #{split.y + split.h} V#{expense.y}$/
    assert reads.d =~ ~r/^M\d+ #{expense.y} V#{split.y + split.h}$/
    assert edge(l, "Split", "Split.Share", :writes).d =~ ~r/^M\d+ \d+ C/
  end

  test "edges from apps higher up run down a lane right of the app column" do
    l = GraphLayout.layout(@forum)
    d = edge(l, "Forum.Post", "Forum.Topic", :writes).d
    assert d =~ ~r/^M302 \d+ H\d+ V\d+ H\d+ V\d+$/
  end

  test "an edge to a store under the column runs down a lane left of it" do
    l = GraphLayout.layout(@forum)
    assert edge(l, "Forum.Post", "Forum.Reply", :writes).d =~ ~r/^M38 \d+ H\d+ V\d+ H\d+ V\d+$/
  end

  test "no two edges cross in the forum graph or the prototype's" do
    # Both are crossing-free by construction: left lanes for stores under
    # the column, right lanes beyond every port they reach, outer lanes on
    # deeper bands and outer ports, exits stacked inner-lowest.
    for graph <- [@forum, @split] do
      l = GraphLayout.layout(graph)

      for {a, i} <- Enum.with_index(l.edges), {b, j} <- Enum.with_index(l.edges), i < j do
        refute crosses?(a, b), "#{a.data} crosses #{b.data}"
      end
    end
  end

  test "exits on a header-only app never coincide: the card grows to hold them" do
    graph = %{
      apps: [%{symbol: "Reader", routes: []}, %{symbol: "Last", routes: []}],
      stores: [
        %{symbol: "S.One", fields: ["id"]},
        %{symbol: "S.Two", fields: ["id"]},
        %{symbol: "S.Three", fields: ["id"]}
      ],
      edges:
        for(s <- ~w(S.One S.Two S.Three), do: %{from: "Reader", to: s, kind: :reads}) ++
          [
            %{from: "Reader", to: "S.Two", kind: :writes},
            %{from: "Reader", to: "S.Three", kind: :writes}
          ]
    }

    l = GraphLayout.layout(graph)
    reader = node(l, "Reader")
    assert reader.body == nil

    exits =
      for e <- l.edges,
          {x, y} <- [hd(GraphLayout.points(e)), List.last(GraphLayout.points(e))],
          x == reader.x or x == reader.x + reader.w,
          do: {round(x), round(y)}

    assert length(exits) == 5
    assert length(Enum.uniq(exits)) == 5
    for {_, y} <- exits, do: assert(y > reader.y and y < reader.y + reader.h)
  end

  test "is deterministic" do
    assert GraphLayout.layout(@forum) == GraphLayout.layout(@forum)
  end

  test "no edge passes through a node box" do
    for graph <- [@forum, @split, wide_graph()] do
      l = GraphLayout.layout(graph)

      for e <- l.edges, {x, y} <- GraphLayout.points(e), n <- l.nodes do
        inside? = x > n.x + 0.5 and x < n.x + n.w - 0.5 and y > n.y + 0.5 and y < n.y + n.h - 0.5
        refute inside?, "#{e.data} crosses #{n.symbol} at #{x},#{y}"
      end
    end
  end

  test "the content extent covers every node and lane" do
    l = GraphLayout.layout(wide_graph())

    for n <- l.nodes do
      assert n.x + n.w <= l.cw
      assert n.y + n.h <= l.ch
    end

    for e <- l.edges, {x, y} <- GraphLayout.points(e) do
      assert x <= l.cw and y <= l.ch
    end
  end

  test "an empty graph lays out nothing" do
    l = GraphLayout.layout(%{apps: [], stores: [], edges: []})
    assert l.nodes == [] and l.edges == []
  end

  # Whether two edges properly cross, over their sampled polylines.
  defp crosses?(a, b) do
    sa = a |> GraphLayout.points() |> Enum.chunk_every(2, 1, :discard)
    sb = b |> GraphLayout.points() |> Enum.chunk_every(2, 1, :discard)
    Enum.any?(sa, fn s -> Enum.any?(sb, &segments_cross?(s, &1)) end)
  end

  defp segments_cross?([{ax, ay}, {bx, by}], [{cx, cy}, {dx, dy}]) do
    d = (bx - ax) * (dy - cy) - (by - ay) * (dx - cx)

    if d == 0 do
      false
    else
      t = ((cx - ax) * (dy - cy) - (cy - ay) * (dx - cx)) / d
      u = ((cx - ax) * (by - ay) - (cy - ay) * (bx - ax)) / d
      t > 0.001 and t < 0.999 and u > 0.001 and u < 0.999
    end
  end

  # Five apps each touching every one of four stores, both ways.
  defp wide_graph do
    apps = for i <- 1..5, do: %{symbol: "App#{i}", routes: ["/a#{i}"]}

    stores =
      for i <- 1..4,
          do: %{symbol: "App.Store#{i}#{String.duplicate("x", i * 3)}", fields: ["id", "a", "b"]}

    edges =
      for a <- apps,
          s <- stores,
          kind <- [:reads, :writes],
          do: %{from: a.symbol, to: s.symbol, kind: kind}

    %{apps: apps, stores: stores, edges: edges}
  end
end
