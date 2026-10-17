defmodule NobiWeb.ConsoleShellTest do
  use NobiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Nobi.UniverseHelpers
  import NobiWeb.ConsoleHelpers

  alias Nobi.{Deployment, Universe}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir}, do: isolated_data(dir)

  @forum File.read!("test/fixtures/nobi/forum.nobi")

  defp forum_universe(prefix \\ "sh") do
    u = fresh_universe(prefix)
    assert {:promoted, _} = Universe.stage(u, "base", @forum)
    u
  end

  describe "the shell" do
    test "a universe page has the top bar, sidebar, title bar and REPL", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")

      {:ok, view, _} = live(conn, "/_/u/#{u}")

      for id <-
            ~w(#console-topbar #console-sidebar #sidebar-deployments #sidebar-envs #console-titlebar #repl-form),
          do: assert(has_element?(view, id), "missing #{id}")

      assert has_element?(view, ~s(#sidebar-deployments a[href="/_/d/#{u}"]))
      assert has_element?(view, ~s(#sidebar-envs a[href="/_/u/#{u}"]))
      assert has_element?(view, ~s(#sidebar-all-envs[href="/_"]))
      assert has_element?(view, "#nav-system")
      assert has_element?(view, "#crumb-universe", u)
      assert has_element?(view, "#view-graph")
      refute has_element?(view, "#repl-echo")
    end

    test "Home and Deployment pages have no views or REPL", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")

      for path <- ["/_", "/_/d/#{u}"] do
        {:ok, view, _} = live(conn, path)
        assert has_element?(view, "#console-topbar")
        assert has_element?(view, "#console-titlebar")
        refute has_element?(view, "#repl-form")
        refute has_element?(view, "#view-graph")
      end
    end

    test "Home's current universe is the last one visited, else main", %{conn: conn} do
      u = forum_universe()

      {:ok, view, _} = live(conn, "/_")
      assert has_element?(view, "#crumb-universe", "main")

      {:ok, view, _} =
        conn |> put_connect_params(%{"console_universe" => u}) |> live("/_")

      assert has_element?(view, "#crumb-universe", u)
    end

    test "hidden features have no nav entry", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}")

      for id <-
            ~w(proposals decisions traces workflows crons queues settings tryit) do
        refute has_element?(view, "#nav-#{id}")
        refute has_element?(view, "#view-#{id}")
      end
    end

    test "the environments list is capped at five", %{conn: conn} do
      for _ <- 1..6, do: fresh_universe("cap")
      {:ok, view, _} = live(conn, "/_")
      n = length(Universe.list())

      assert has_element?(view, "#sidebar-all-envs", "All #{n} environments")

      rows =
        view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#sidebar-envs > a")

      assert Enum.count(rows) == 5
    end
  end

  describe "the palette" do
    test "opens, filters and closes", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")
      {:ok, view, _} = live(conn, "/_/u/#{u}")

      refute has_element?(view, "#cmd-palette")
      view |> element("#cmd-open") |> render_click()
      assert has_element?(view, "#cmd-palette")
      assert has_element?(view, ~s(#cmd-items a[href="/_/u/#{u}?sel=Forum.Threads"]))
      assert has_element?(view, ~s(#cmd-items a[href="/_/u/#{u}?view=data&store=Forum.Topic"]))

      assert has_element?(
               view,
               ~s(#cmd-items a[href="/_/u/#{u}?view=code&sym=Forum.Threads.init"])
             )

      assert has_element?(view, ~s(#cmd-items a[href="/_/d/#{u}"]))
      assert has_element?(view, ~s(#cmd-items a[href="/_/u/#{u}"]))

      view |> form("#cmd-form", cmd: %{q: "topic"}) |> render_change()
      assert has_element?(view, ~s(#cmd-items a[href="/_/u/#{u}?view=data&store=Forum.Topic"]))
      refute has_element?(view, ~s(#cmd-items a[href="/_/u/#{u}?sel=Forum.Threads"]))

      render_hook(view, "console:palette-close", %{})
      refute has_element?(view, "#cmd-palette")

      render_hook(view, "console:palette-toggle", %{})
      assert has_element?(view, "#cmd-palette")
      render_hook(view, "console:palette-toggle", %{})
      refute has_element?(view, "#cmd-palette")
    end
  end

  describe "the intro" do
    test "opens, pages next and back, and closes", %{conn: conn} do
      {:ok, view, _} = live(conn, "/_")

      refute has_element?(view, "#intro")
      view |> element("#intro-open") |> render_click()
      assert has_element?(view, ~s(#intro[data-page="0"]))

      view |> element("#intro-next") |> render_click()
      assert has_element?(view, ~s(#intro[data-page="1"]))

      view |> element("#intro-back") |> render_click()
      assert has_element?(view, ~s(#intro[data-page="0"]))

      view |> element("#intro-next") |> render_click()
      # the last page's Next closes
      view |> element("#intro-next") |> render_click()
      refute has_element?(view, "#intro")

      view |> element("#intro-open") |> render_click()
      view |> element("#intro-skip") |> render_click()
      refute has_element?(view, "#intro")

      # Esc: ConsoleKeys pushes this event when the intro is open
      view |> element("#intro-open") |> render_click()
      render_hook(view, "console:intro-close", %{})
      refute has_element?(view, "#intro")
    end
  end

  describe "the sidebar" do
    test "follows a roll back and a follow on the deployment page", %{conn: conn} do
      u = forum_universe()
      assert {:promoted, _} = Universe.stage(u, "more", "def Forum.more() : Int do\n  1\nend")
      :ok = Deployment.create(u, u, "Forum")
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      assert has_element?(view, ~s(#sidebar-dep-#{u}[data-hue=mint]))
      view |> element("#dep-ver-1 button") |> render_click()
      assert has_element?(view, ~s(#sidebar-dep-#{u}[data-hue=grey]))
      view |> element("#dep-promote-btn") |> render_click()
      assert has_element?(view, ~s(#sidebar-dep-#{u}[data-hue=mint]))
    end

    test "a pin from elsewhere and a new deployment show without navigating", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")
      {:ok, view, _} = live(conn, "/_/d/#{u}")

      other = u <> "-b"
      :ok = Deployment.create(other, u, "Forum")
      :ok = Deployment.pin(u, 1)

      eventually(view, ~s(#sidebar-dep-#{u}[data-hue=grey]))
      assert has_element?(view, "#sidebar-dep-#{other}")
    end
  end

  describe "the REPL" do
    test "evaluates an expression and echoes it", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}")

      view |> form("#repl-form", repl: %{expr: "1 + 2"}) |> render_submit()
      assert has_element?(view, "#repl-echo [data-ok]", "ok · 3")
    end

    test "shows a record, an Option and a string as the MCP eval does", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}")

      for expr <- [~s(%Forum.Topic{title: "Hi", replies: 2}), "Option.Some(1)", ~s("hi")] do
        {:ok, value, type} = Universe.eval(u, expr)
        shown = Nobi.Exec.show(value, type)

        view |> form("#repl-form", repl: %{expr: expr}) |> render_submit()
        assert has_element?(view, "#repl-echo [data-ok]", "ok · " <> shown)
        refute has_element?(view, "#repl-echo [data-ok]", "{:")
      end

      assert has_element?(view, "#repl-echo [data-ok]", ~s("hi"))
    end

    test "shows the reason of a failing expression", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}")

      view |> form("#repl-form", repl: %{expr: "Forum.Nope.f()"}) |> render_submit()
      assert has_element?(view, "#repl-echo [data-error]")
    end
  end
end
