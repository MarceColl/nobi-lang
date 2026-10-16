defmodule KinokoWeb.ConsoleGraphTest do
  @moduledoc "`/_/u/:universe`'s System graph: nodes, edges, inspector, degrade states."
  use KinokoWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Kinoko.UniverseHelpers
  import KinokoWeb.ConsoleHelpers

  alias Kinoko.{Data, Deployment, Universe}

  # Deployments' data files land in this test's own directory.
  @moduletag :tmp_dir
  setup %{tmp_dir: dir}, do: isolated_data(dir)

  @forum File.read!("test/fixtures/yabu/forum.yabu")

  defp forum_universe do
    u = fresh_universe("gr")
    assert {:promoted, _} = Universe.stage(u, "base", @forum)
    u
  end

  test "renders a node per app and store, and an edge per read and write", %{conn: conn} do
    u = forum_universe()
    {:ok, view, _} = live(conn, "/_/u/#{u}")

    for id <- ~w(Forum-Threads Forum-Post Forum-Settings Forum-Topic Forum-Reply),
        do: assert(has_element?(view, "#graph-world #node-#{id}"))

    assert has_element?(view, ~s([data-edge="Forum.Threads->Forum.Topic:writes"]))
    assert has_element?(view, ~s([data-edge="Forum.Threads->Forum.Topic:reads"]))
    assert has_element?(view, ~s([data-edge="Forum.Post->Forum.Reply:writes"]))
    refute has_element?(view, ~s([data-edge^="Forum.Settings->"]))

    # the interim summary is gone, the camera, zoom strip and legend are there
    refute has_element?(view, "#universe-name")
    assert has_element?(view, "#graph-canvas[phx-hook=GraphCamera]")
    assert has_element?(view, "#graph-zoom-in")
    assert has_element?(view, "#graph-fit")
    assert has_element?(view, "#graph-legend")
    assert has_element?(view, "#graph-hint")
  end

  test "a store with no deployment reads no data; a served one counts its rows", %{conn: conn} do
    u = forum_universe()
    {:ok, view, _} = live(conn, "/_/u/#{u}")
    assert view |> element("#node-Forum-Topic [data-rows]") |> render() =~ "no data"

    :ok = Deployment.create(u, u, "Forum")
    {:ok, image} = Universe.image(u)
    models = image.module.__yabu__(:models)
    {:ok, repo} = Data.open(u)

    for t <- ~w(one two),
        do:
          {:ok, _} =
            Data.insert(
              repo,
              "Forum.Topic",
              models,
              {:rec, "Forum.Topic", %{"title" => t, "replies" => 0}}
            )

    {:ok, view, _} = live(conn, "/_/u/#{u}")
    assert view |> element("#node-Forum-Topic [data-rows]") |> render() =~ "2 rows"
  end

  test "clicking an app opens the inspector; × closes it", %{conn: conn} do
    u = forum_universe()
    :ok = Deployment.create(u, u, "Forum")
    {:ok, view, _} = live(conn, "/_/u/#{u}")
    refute has_element?(view, "#inspector")

    view |> element("#node-Forum-Threads") |> render_click()
    assert_patch(view, "/_/u/#{u}?sel=Forum.Threads")

    assert has_element?(view, "#inspector")
    assert has_element?(view, "#node-Forum-Threads[data-selected]")
    refute has_element?(view, "#graph-hint")
    assert has_element?(view, ~s(#inspector [data-row="model"]), "Forum.Threads.Model · 3 fields")
    assert has_element?(view, ~s(#inspector [data-row="data"]), "Forum.Topic")
    assert has_element?(view, ~s(#inspector [data-row="serving"]), u)

    view |> element("#inspector-close") |> render_click()
    assert_patch(view, "/_/u/#{u}")
    refute has_element?(view, "#inspector")
    assert has_element?(view, "#graph-hint")
  end

  test "a store's inspector lists who writes and reads it, and its newest rows", %{conn: conn} do
    u = forum_universe()
    :ok = Deployment.create(u, u, "Forum")
    {:ok, models} = Universe.models(u)
    {:ok, repo} = Data.open(u)

    # six rows, more than the sample's four
    for i <- 1..6,
        do:
          {:ok, _} =
            Data.insert(
              repo,
              "Forum.Topic",
              models,
              {:rec, "Forum.Topic", %{"title" => "topic-#{i}", "replies" => 1}}
            )

    {:ok, view, _} = live(conn, "/_/u/#{u}?sel=Forum.Topic")
    assert has_element?(view, ~s(#inspector [data-row="written by"]), "Forum.Post")
    assert has_element?(view, ~s(#inspector [data-row="read by"]), "Forum.Threads")
    assert has_element?(view, ~s(#inspector [data-row="layer"]), u)

    assert has_element?(
             view,
             ~s(#inspector-open-data[href="/_/u/#{u}?view=data&store=Forum.Topic"])
           )

    # the four newest, newest first; the rest counted from the file's row count
    for {i, nth} <- Enum.zip(6..3//-1, 1..4),
        do:
          assert(
            has_element?(
              view,
              "#inspector-rows [data-sample-row]:nth-child(#{nth})",
              "topic-#{i}"
            )
          )

    refute has_element?(view, "#inspector-rows [data-sample-row]:nth-child(5)")
    refute has_element?(view, "#inspector-rows [data-sample-row]", "topic-2")
    assert has_element?(view, "#inspector-more", "+2 more")
  end

  test "a click on empty canvas clears the selection", %{conn: conn} do
    u = forum_universe()
    {:ok, view, _} = live(conn, "/_/u/#{u}?sel=Forum.Topic")
    assert has_element?(view, "#inspector")

    render_hook(view, "graph:deselect", %{})
    assert_patch(view, "/_/u/#{u}")
    refute has_element?(view, "#inspector")
  end

  test "an unknown selection opens nothing", %{conn: conn} do
    u = forum_universe()
    {:ok, view, _} = live(conn, "/_/u/#{u}?sel=Nope")
    refute has_element?(view, "#inspector")
  end

  test "an empty universe shows the empty state", %{conn: conn} do
    u = fresh_universe("gr")
    {:ok, view, _} = live(conn, "/_/u/#{u}")
    assert has_element?(view, "#graph-empty")
    refute has_element?(view, "#graph-canvas")
  end

  test "a degraded universe shows why", %{conn: conn} do
    u = fresh_universe("gr")
    store_commit(u, "def A.f() : Int do\n  A.g()\nend")

    capture_log(fn ->
      {:ok, view, _} = live(conn, "/_/u/#{u}")
      assert has_element?(view, "#graph-degraded")
      assert has_element?(view, "#graph-degraded [data-reason]", "A.f")
      refute has_element?(view, "#graph-canvas")
    end)
  end

  test "a commit adds its node live", %{conn: conn} do
    u = forum_universe()
    {:ok, view, _} = live(conn, "/_/u/#{u}")
    refute has_element?(view, "#node-Forum-Tag")

    assert {:promoted, _} =
             Universe.stage(u, "tag", """
             defmodel Forum.Tag do
               id : Uuid
               name : String
             end
             """)

    eventually(view, "#node-Forum-Tag")
  end

  test "the code and data views open no graph and no inspector", %{conn: conn} do
    u = forum_universe()

    for v <- ~w(code data) do
      {:ok, view, _} = live(conn, "/_/u/#{u}?view=#{v}&sel=Forum.Topic")
      refute has_element?(view, "#graph-canvas")
      refute has_element?(view, "#inspector")
    end
  end
end
