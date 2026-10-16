defmodule KinokoWeb.ConsoleDeploymentTest do
  @moduledoc "`/_/d/:name`: header, promote callout, deployed versions, routes, stored models."
  use KinokoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kinoko.UniverseHelpers

  alias Kinoko.{Data, Deployment, Universe}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir}, do: isolated_data(dir)

  @forum File.read!("test/fixtures/yabu/forum.yabu")

  # A universe with three promoted rounds; commit 1 is the forum.
  defp universe(rounds \\ 3) do
    u = fresh_universe("dp")
    assert {:promoted, _} = Universe.stage(u, "base", @forum)

    for i <- 2..rounds//1 do
      assert {:promoted, _} =
               Universe.stage(u, "extra-#{i}", "def Forum.extra#{i}() : Int do\n  #{i}\nend")
    end

    u
  end

  defp head(u), do: length(Universe.history(u))

  describe "header" do
    test "a following deployment: name, chip, URL, serving line, Open, no Promote", %{conn: conn} do
      u = universe()
      :ok = Deployment.create(u, u, "Forum", hosts: ["#{u}.test"])
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      assert has_element?(view, "#dep-header #deployment-name", u)
      assert has_element?(view, "#dep-header #deployment-commit[data-mode=following]")
      assert has_element?(view, ~s(#dep-url[href^="http://#{u}.test"]))
      assert has_element?(view, ~s(#dep-serving a[href="/_/u/#{u}"]))
      assert has_element?(view, "#dep-serving", "commit ##{head(u)}")
      assert has_element?(view, ~s(#dep-open[target=_blank]))
      refute has_element?(view, "#dep-promote-btn")
      refute has_element?(view, "#dep-promote")
    end

    test "without hosts the URL is <name>.localhost", %{conn: conn} do
      u = universe(1)
      :ok = Deployment.create(u, u, "Forum")
      {:ok, view, _} = live(conn, "/_/d/#{u}")
      assert has_element?(view, ~s(#dep-url[href^="http://#{u}.localhost"]))
    end

    test "a pinned deployment shows the pinned chip, its commit and Promote", %{conn: conn} do
      u = universe()
      :ok = Deployment.create(u, u, "Forum", commit: 1)
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      assert has_element?(view, "#deployment-commit[data-mode=pinned]")
      assert has_element?(view, "#dep-serving", "commit #1")
      assert has_element?(view, "#dep-promote-btn", "Promote #{u}")
    end

    test "Promote follows head", %{conn: conn} do
      u = universe()
      :ok = Deployment.create(u, u, "Forum", commit: 1)
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      view |> element("#dep-promote-btn") |> render_click()
      assert {:ok, %{commit: nil}} = Deployment.get(u)
      assert has_element?(view, "#deployment-commit[data-mode=following]")
      refute has_element?(view, "#dep-promote-btn")
    end
  end

  describe "promote callout" do
    test "only when pinned behind head, counting the commits ahead", %{conn: conn} do
      u = universe()
      :ok = Deployment.create(u, u, "Forum", commit: 1)
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      assert has_element?(view, "#dep-promote", "2 commits ahead")
      assert has_element?(view, "#dep-promote", "extra-2")
      assert has_element?(view, "#dep-promote", "extra-3")
    end

    test "absent when following, or when pinned at head", %{conn: conn} do
      u = universe()
      :ok = Deployment.create(u, u, "Forum")
      {:ok, view, _} = live(conn, "/_/d/#{u}")
      refute has_element?(view, "#dep-promote")

      :ok = Deployment.pin(u, head(u))
      eventually(view, fn -> has_element?(view, "#deployment-commit[data-mode=pinned]") end)
      refute has_element?(view, "#dep-promote")
    end
  end

  describe "deployed versions" do
    test "history newest first; the head is current while following", %{conn: conn} do
      u = universe()
      :ok = Deployment.create(u, u, "Forum")
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      for n <- 1..3, do: assert(has_element?(view, "#dep-versions #dep-ver-#{n}"))
      assert has_element?(view, "#dep-ver-3[data-current] .dep-current", "current")
      refute has_element?(view, "#dep-ver-2[data-current]")
      assert has_element?(view, "#dep-ver-2 button", "roll back")
      assert has_element?(view, "#dep-ver-1 button", "roll back")
      assert has_element?(view, "#dep-ver-3", "extra-3")
      assert has_element?(view, "#dep-ver-3 .dep-symbols", "+1")
      assert has_element?(view, "#dep-ver-3 .dep-symbols", "−0")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#dep-versions [id^=dep-ver-]")

      assert ids |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd())) ==
               ["dep-ver-3", "dep-ver-2", "dep-ver-1"]
    end

    test "roll back pins that commit and its row becomes current", %{conn: conn} do
      u = universe()
      :ok = Deployment.create(u, u, "Forum")
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      view |> element("#dep-ver-2 button") |> render_click()

      assert {:ok, %{commit: 2}} = Deployment.get(u)
      assert has_element?(view, "#dep-ver-2[data-current]")
      refute has_element?(view, "#dep-ver-3[data-current]")
      assert has_element?(view, "#deployment-commit[data-mode=pinned]")
      assert has_element?(view, "#dep-serving", "commit #2")
      assert has_element?(view, "#dep-ver-3 button", "follow head")
    end

    test "follow head on the head row returns to following", %{conn: conn} do
      u = universe()
      :ok = Deployment.create(u, u, "Forum", commit: 1)
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      assert has_element?(view, "#dep-ver-1[data-current]")
      view |> element("#dep-ver-3 button", "follow head") |> render_click()

      assert {:ok, %{commit: nil}} = Deployment.get(u)
      assert has_element?(view, "#dep-ver-3[data-current]")
    end

    test "a new universe commit adds a row", %{conn: conn} do
      u = universe(2)
      :ok = Deployment.create(u, u, "Forum")
      {:ok, view, _} = live(conn, "/_/d/#{u}")
      refute has_element?(view, "#dep-ver-3")

      assert {:promoted, _} = Universe.stage(u, "later", "def Forum.later() : Int do\n  9\nend")
      eventually(view, fn -> has_element?(view, "#dep-ver-3[data-current]") end)
    end

    test "a pin from elsewhere refreshes the page", %{conn: conn} do
      u = universe()
      :ok = Deployment.create(u, u, "Forum")
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      :ok = Deployment.pin(u, 1)
      eventually(view, fn -> has_element?(view, "#dep-ver-1[data-current]") end)
    end
  end

  describe "routes" do
    test "pattern, app, and a link only for parameter-free paths", %{conn: conn} do
      u = universe(1)
      :ok = Deployment.create(u, u, "Forum", hosts: ["#{u}.test"])
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      assert has_element?(view, "#dep-routes")

      assert has_element?(
               view,
               ~s(#dep-routes a[data-path="/settings"][href^="http://#{u}.test"])
             )

      assert has_element?(view, ~s(#dep-routes [data-pattern="/post/:id"]))
      refute has_element?(view, ~s(#dep-routes a[data-path="/post/:id"]))
      assert has_element?(view, ~s(#dep-routes [data-pattern="/post/:id"] .dep-app), "Forum.Post")
    end
  end

  describe "hosts" do
    test "lists the implicit localhost host and every extra host, once", %{conn: conn} do
      u = universe(1)
      :ok = Deployment.create(u, u, "Forum", hosts: ["#{u}.test", "#{u}.localhost"])
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      assert has_element?(view, "#dep-hosts")

      assert has_element?(
               view,
               ~s(#dep-hosts [data-host="#{u}.test"] a[href^="http://#{u}.test"])
             )

      assert has_element?(view, ~s(#dep-hosts [data-host="#{u}.localhost"]))

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#dep-hosts [data-host]")
             |> Enum.count() == 2
    end
  end

  describe "stored models" do
    test "empty, then rows and columns", %{conn: conn} do
      u = universe(1)
      :ok = Deployment.create(u, u, "Forum")

      {:ok, view, _} = live(conn, "/_/d/#{u}")
      assert has_element?(view, "#dep-models-empty")
      refute has_element?(view, "#dep-models [data-model]")

      {:ok, models} = Universe.models(u)
      {:ok, repo} = Data.open(u)
      topic = {:rec, "Forum.Topic", %{"title" => "Hi", "replies" => 0}}
      for _ <- 1..2, do: {:ok, _} = Data.insert(repo, "Forum.Topic", models, topic)
      :ok = Data.ensure(repo, "Forum.Reply", models)

      {:ok, view, _} = live(conn, "/_/d/#{u}")
      assert has_element?(view, ~s(#dep-models [data-model="Forum.Topic"] [data-rows="2"]))
      assert has_element?(view, ~s(#dep-models [data-model="Forum.Reply"] [data-rows="0"]))
      assert has_element?(view, ~s(#dep-models [data-model="Forum.Topic"] .dep-columns), "title")

      assert has_element?(
               view,
               ~s(#dep-models [data-model="Forum.Topic"] .dep-columns),
               "replies"
             )
    end
  end

  defp eventually(view, check, ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn ->
      _ = render(view)
      check.() or (Process.sleep(5) && false)
    end)
    |> Enum.find(&(&1 or System.monotonic_time(:millisecond) > deadline))
    |> then(&assert(&1, "never held:\n#{render(view)}"))
  end
end
