defmodule KinokoWeb.ConsoleCodeDataTest do
  @moduledoc "`/_/u/:universe?view=code` and `?view=data`: symbols, source, staged reasons, rows."
  use KinokoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kinoko.UniverseHelpers

  alias Kinoko.{Data, Deployment, Universe}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir}, do: isolated_data(dir)

  @forum File.read!("test/fixtures/yabu/forum.yabu")

  defp forum_universe do
    u = fresh_universe("cd")
    assert {:promoted, _} = Universe.stage(u, "base", @forum)
    u
  end

  defp insert_topics(u, titles) do
    {:ok, models} = Universe.models(u)
    {:ok, repo} = Data.open(u)

    for {t, i} <- Enum.with_index(titles),
        do:
          {:ok, _} =
            Data.insert(
              repo,
              "Forum.Topic",
              models,
              {:rec, "Forum.Topic", %{"title" => t, "replies" => i}}
            )
  end

  describe "code" do
    test "lists the symbols, grouped by namespace, the first one open", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}?view=code")

      assert has_element?(view, "#symbols #symgroup-Forum")
      assert has_element?(view, "#symbols #sym-Forum-Topic")
      assert has_element?(view, "#symbols #sym-Forum-Threads-update")
      assert has_element?(view, "#sym-Forum-Topic [data-committed]")
      assert has_element?(view, "#symbols-count", "#{length(Universe.symbols(u))}")
      # `Forum` (the route table) sorts first
      assert has_element?(view, "#sym-Forum[data-selected]")
      refute has_element?(view, "#sym-Forum-Post[data-selected]")
      assert has_element?(view, "#code-symbol", "Forum")
    end

    test "selecting a symbol shows its source with line numbers", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}?view=code")

      view |> element("#sym-Forum-Threads-update") |> render_click()
      assert_patch(view, "/_/u/#{u}?view=code&sym=Forum.Threads.update")

      assert has_element?(view, "#code-symbol", "Forum.Threads.update")
      assert has_element?(view, "#code-chip", "typechecks")
      assert has_element?(view, "#code-cid", "sha256 ")
      assert has_element?(view, "#source #line-1 [data-n]", "1")
      assert has_element?(view, "#source #line-1 [data-kw]", "def")
      assert has_element?(view, "#source #line-2")
      refute has_element?(view, "#staged-reasons")

      {:ok, text} = Universe.read(u, "Forum.Threads.update")
      n = text |> String.split("\n") |> length()
      assert has_element?(view, "#source #line-#{n}")
      refute has_element?(view, "#source #line-#{n + 1}")
    end

    test "Show on the graph selects an app's node, else opens the graph", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}?view=code&sym=Forum.Topic")
      assert has_element?(view, ~s(#code-show-graph[href="/_/u/#{u}?view=graph&sel=Forum.Topic"]))

      {:ok, view, _} = live(conn, "/_/u/#{u}?view=code&sym=Forum.Threads.update")
      assert has_element?(view, ~s(#code-show-graph[href="/_/u/#{u}"]))
    end

    test "a staged patch is marked STAGED with its id and lists its reasons", %{conn: conn} do
      u = forum_universe()

      assert {:staged, [_ | _]} =
               Universe.stage(u, "p1", """
               def Forum.broken() : Int do
                 Forum.missing()
               end
               """)

      {:ok, view, _} = live(conn, "/_/u/#{u}?view=code")
      assert has_element?(view, "#sym-Forum-broken [data-staged]", "p1")
      refute has_element?(view, "#staged-reasons")

      view |> element("#sym-Forum-broken") |> render_click()
      assert_patch(view, "/_/u/#{u}?view=code&sym=Forum.broken")

      assert has_element?(view, "#code-chip", "staged · ")
      refute has_element?(view, "#code-cid")
      assert has_element?(view, "#source #line-1")
      assert has_element?(view, "#staged-reasons", "p1")
      assert has_element?(view, "#staged-reasons [data-reason]", "Forum.missing")
    end

    test "an empty universe shows the empty state", %{conn: conn} do
      u = fresh_universe("cd")
      {:ok, view, _} = live(conn, "/_/u/#{u}?view=code")
      assert has_element?(view, "#code-empty")
      refute has_element?(view, "#symbols")
    end
  end

  describe "data" do
    test "with no deployment, the empty state", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}?view=data")
      assert has_element?(view, "#data-empty", "No data yet")
      refute has_element?(view, "#data-table")
    end

    test "the table holds the store's rows, newest first", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")
      insert_topics(u, ~w(alpha beta gamma))

      {:ok, view, _} = live(conn, "/_/u/#{u}?view=data&store=Forum.Topic")

      assert has_element?(view, "#data-note", "deployment #{u}")
      assert has_element?(view, "#data-cols [data-col]:first-child", "id")
      assert has_element?(view, ~s(#data-cols [data-col="replies"]))
      assert has_element?(view, "#data-rows [data-row]:nth-child(3)")
      refute has_element?(view, "#data-rows [data-row]:nth-child(4)")
      assert has_element?(view, "#data-rows [data-row]:first-child", "gamma")
      assert has_element?(view, "#data-rows [data-row]:nth-child(3)", "alpha")
      assert has_element?(view, ~s(#data-rows [data-row]:first-child [data-cell="replies"]), "2")
      assert has_element?(view, "#data-footer", "3 rows · written by Forum.Post")
      refute has_element?(view, "#data-dep")
      assert has_element?(view, "#console-subtitle", "Forum.Topic · 3 rows")
    end

    test "switching the store re-reads the table", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")
      insert_topics(u, ~w(alpha))

      # the first store, `Forum.Reply`, is open by default
      {:ok, view, _} = live(conn, "/_/u/#{u}?view=data")
      assert has_element?(view, ~s(#data-store option[value="Forum.Reply"][selected]))
      assert has_element?(view, ~s(#data-cols [data-col="body"]))
      refute has_element?(view, "#data-rows [data-row]")
      assert has_element?(view, "#data-footer", "0 rows")

      view |> form("#data-form", data: %{store: "Forum.Topic"}) |> render_change()
      assert_patch(view, "/_/u/#{u}?view=data&store=Forum.Topic")

      assert has_element?(view, ~s(#data-store option[value="Forum.Topic"][selected]))
      assert has_element?(view, ~s(#data-cols [data-col="title"]))
      assert has_element?(view, "#data-rows [data-row]", "alpha")
      assert has_element?(view, "#data-footer", "1 row · written by Forum.Post")
    end

    test "above 200 rows, the newest 200 are shown", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")
      insert_topics(u, for(i <- 1..201, do: "t#{i}"))

      {:ok, view, _} = live(conn, "/_/u/#{u}?view=data&store=Forum.Topic")
      assert has_element?(view, "#data-rows [data-row]:nth-child(200)")
      refute has_element?(view, "#data-rows [data-row]:nth-child(201)")
      assert has_element?(view, "#data-rows [data-row]:first-child", "t201")
      assert has_element?(view, "#data-footer", "201 rows · showing 200")
    end

    test "a second deployment adds its selector", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")
      other = u <> "-b"
      :ok = Deployment.create(other, u, "Forum")
      insert_topics(u, ~w(alpha))

      {:ok, view, _} = live(conn, "/_/u/#{u}?view=data&store=Forum.Topic")
      assert has_element?(view, ~s(#data-dep option[value="#{other}"]))
      assert has_element?(view, "#data-rows [data-row]")

      view
      |> form("#data-form", data: %{store: "Forum.Topic", dep: other})
      |> render_change()

      assert_patch(view, "/_/u/#{u}?view=data&store=Forum.Topic&dep=#{other}")
      assert has_element?(view, "#data-note", "deployment #{other}")
      refute has_element?(view, "#data-rows [data-row]")
    end
  end
end
