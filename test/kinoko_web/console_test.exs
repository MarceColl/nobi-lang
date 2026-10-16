defmodule KinokoWeb.ConsoleTest do
  use KinokoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kinoko.UniverseHelpers

  alias Kinoko.{Deployment, Universe}

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
      assert has_element?(view, ~s(a#{id("env", u)}[href="/_/u/#{u}"]))
      assert has_element?(view, ~s(a#{id("dep", u)}[href="/_/d/#{u}"]))
    end
  end

  describe "/_/u/:universe" do
    test "shows the system graph", %{conn: conn} do
      u = forum_universe()
      :ok = Deployment.create(u, u, "Forum")

      {:ok, view, _} = live(conn, "/_/u/#{u}")

      assert has_element?(view, "#node-Forum-Threads")
      assert has_element?(view, "#node-Forum-Topic")
      assert has_element?(view, ~s([data-edge="Forum.Threads->Forum.Topic:writes"]))
    end

    test "refreshes live after a commit", %{conn: conn} do
      u = forum_universe()
      {:ok, view, _} = live(conn, "/_/u/#{u}")
      refute has_element?(view, "#node-Forum-Extra")

      assert {:promoted, _} =
               Universe.stage(u, "extra", """
               defmodel Forum.Extra do
                 id : Uuid
                 n : Int
               end
               """)

      eventually(view, "#node-Forum-Extra")
    end

    test "an unknown universe goes back to the index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/_"}}} = live(conn, "/_/u/nope-nope")
    end
  end

  describe "/_/d/:name" do
    test "an unknown deployment goes back to the index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/_"}}} = live(conn, "/_/d/nope-nope")
    end
  end
end
