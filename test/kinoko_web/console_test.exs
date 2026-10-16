defmodule KinokoWeb.ConsoleTest do
  use KinokoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kinoko.UniverseHelpers

  alias Kinoko.{Data, Deployment, Universe}

  # Deployments' data files land in this test's own directory.
  @moduletag :tmp_dir
  setup %{tmp_dir: dir}, do: isolated_data(dir)

  @forum File.read!("test/fixtures/yabu/forum.yabu")

  defp forum_universe(prefix \\ "con") do
    u = fresh_universe(prefix)
    assert {:promoted, _} = Universe.stage(u, "base", @forum)
    u
  end

  defp id(prefix, name), do: ~s([id="#{prefix}-#{name}"])

  defp eventually(view, selector, ms \\ 5_000),
    do: eventually(view, selector, System.monotonic_time(:millisecond) + ms, nil)

  defp eventually(view, selector, deadline, _) do
    cond do
      has_element?(view, selector) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("never appeared: #{selector}\n#{render(view)}")

      true ->
        receive do
        after
          2 -> eventually(view, selector, deadline, nil)
        end
    end
  end

  describe "/_" do
    test "lists universes and deployments with links", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum", hosts: ["#{u}.test"])

      {:ok, view, _} = live(conn, "/_")

      assert has_element?(view, "#console-index")
      assert has_element?(view, id("universes", u))
      assert has_element?(view, ~s(a#{id("universes", u)}[href="/_/u/#{u}"]))
      assert has_element?(view, id("deployments", u))
      assert has_element?(view, ~s(a#{id("deployments", u)}[href="/_/d/#{u}"]))
    end
  end

  describe "/_/u/:universe" do
    test "shows apps, routes, symbols, history and health", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")

      {:ok, view, _} = live(conn, "/_/u/#{u}")

      assert has_element?(view, "#universe-name")
      assert has_element?(view, "#health[data-state=ok]")
      assert has_element?(view, id("app", "Forum.Threads"))
      # the app links to the deployment serving it
      assert has_element?(view, ~s(#{id("app", "Forum.Threads")} a[href="/_/d/#{u}"]))
      assert has_element?(view, id("route-table", "Forum"))
      assert has_element?(view, ~s(#{id("route-table", "Forum")} [data-pattern="/post/:id"]))
      assert has_element?(view, id("symbol", "Forum.Threads.init"))
      assert has_element?(view, "#history [id^=history-]")
    end

    test "shows staged patches with their reasons", %{conn: conn} do
      u = forum_universe()

      assert {:staged, _} =
               Universe.stage(u, "broken", """
               def Forum.Broken.f() : Int do
                 Forum.Missing.g()
               end
               """)

      {:ok, view, _} = live(conn, "/_/u/#{u}")
      assert has_element?(view, id("staged", "broken"))
      assert has_element?(view, ~s(#{id("staged", "broken")} [data-reason]))
    end

    test "refreshes live after a commit", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}")
      refute has_element?(view, id("symbol", "Forum.Extra.answer"))

      assert {:promoted, _} =
               Universe.stage(u, "extra", "def Forum.Extra.answer() : Int do 42 end")

      eventually(view, id("symbol", "Forum.Extra.answer"))
    end

    test "an unknown universe goes back to the index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/_"}}} = live(conn, "/_/u/nope-nope")
    end
  end

  describe "/_/d/:name" do
    test "shows the deployment, its hosts and clickable paths", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum", hosts: ["#{u}.test"])

      {:ok, view, _} = live(conn, "/_/d/#{u}")

      assert has_element?(view, "#deployment-name")
      assert has_element?(view, ~s(a[href="/_/u/#{u}"]))
      assert has_element?(view, "#deployment-commit[data-mode=following]")
      assert has_element?(view, ~s(#hosts a[href^="http://#{u}.test"]))
      # a param-free entry is a link, a parameterised one is not
      assert has_element?(view, ~s(#routes a[data-path="/settings"]))
      assert has_element?(view, ~s(#routes [data-pattern="/post/:id"]))
      refute has_element?(view, ~s(#routes a[data-path="/post/:id"]))
    end

    test "shows the stored models: row counts and columns", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")

      {:ok, view, _} = live(conn, "/_/d/#{u}")
      assert has_element?(view, "#models-empty")
      refute has_element?(view, "#models article")

      {:ok, image} = Universe.image(u)
      models = image.module.__yabu__(:models)
      {:ok, repo} = Data.open(u)
      topic = {:rec, "Forum.Topic", %{"title" => "Hi", "replies" => 0}}
      for _ <- 1..2, do: {:ok, _} = Data.insert(repo, "Forum.Topic", models, topic)
      :ok = Data.ensure(repo, "Forum.Reply", models)

      {:ok, view, _} = live(conn, "/_/d/#{u}")
      assert has_element?(view, ~s(#{id("models", "Forum.Topic")} [data-table="forum__topic"]))
      assert has_element?(view, ~s(#{id("models", "Forum.Topic")} [data-rows="2"]))
      assert has_element?(view, ~s(#{id("models", "Forum.Reply")} [data-rows="0"]))

      for {col, type} <- [{"id", "TEXT"}, {"title", "TEXT"}, {"replies", "INTEGER"}],
          do:
            assert(
              has_element?(
                view,
                ~s(#{id("models", "Forum.Topic")} [data-column="#{col}"][data-type="#{type}"])
              )
            )
    end

    test "shows a pinned commit", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum", commit: 1)
      {:ok, view, _} = live(conn, "/_/d/#{u}")
      assert has_element?(view, "#deployment-commit[data-mode=pinned]")
    end

    test "an unknown deployment goes back to the index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/_"}}} = live(conn, "/_/d/nope-nope")
    end
  end
end
