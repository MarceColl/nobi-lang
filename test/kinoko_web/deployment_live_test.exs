defmodule KinokoWeb.DeploymentLiveTest do
  use KinokoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kinoko.UniverseHelpers

  alias Kinoko.{Deployment, Universe}

  @forum File.read!("test/fixtures/yabu/forum.yabu")
  @lab File.read!("test/fixtures/yabu/lab.yabu")
  @uuid "0b6f9a52-4d1e-4c3a-9f7e-2a1b3c4d5e6f"

  # A route with a param and an app whose click navigates to it.
  @jump """
  defmodel Forum.Jump.Model do
    target : Uuid
  end

  deftype Forum.Jump.Msg do
    Go
  end

  def Forum.Jump.init(id : Uuid) : (Forum.Jump.Model, Cmd<Forum.Jump.Msg>) do
    (%Forum.Jump.Model{target: id}, Cmd.none())
  end

  def Forum.Jump.update(msg : Forum.Jump.Msg, model : Forum.Jump.Model) : (Forum.Jump.Model, Cmd<Forum.Jump.Msg>) do
    case msg do
      Forum.Jump.Msg.Go -> (model, Cmd.navigate(Forum.Post, model.target))
    end
  end

  def Forum.Jump.view(model : Forum.Jump.Model) : Html<Forum.Jump.Msg> do
    <button id="go" on-click={Forum.Jump.Msg.Go}>Go</button>
  end

  defapp Forum.Jump

  defroutes Forum do
    "/" -> Forum.Threads
    "/post/:id" -> Forum.Post
    "/settings" -> Forum.Settings
    "/jump/:id" -> Forum.Jump
  end
  """

  # ---------- helpers ----------

  # A fresh universe with `source` promoted, and a deployment of the same
  # name serving route table `routes` (`opts` as `Deployment.create/4`'s).
  defp deploy(source, routes, opts \\ []) do
    u = fresh_universe("dl")
    assert {:promoted, _} = Universe.stage(u, "base", source)
    :ok = Deployment.create(u, u, routes, opts)
    u
  end

  defp on_host(conn, name), do: %{conn | host: "#{name}.localhost"}

  defp open(conn, name, path) do
    {:ok, view, html} = live(on_host(conn, name), path)
    # One round trip: the connected mount's own msgs (its commit
    # subscription) are handled before anything the test does next.
    render(view)
    {view, html}
  end

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp click(view, id), do: render_click(view, "yabu", %{"click" => id})

  defp change(view, id, value),
    do: render_change(view, "yabu", %{"_target" => ["yabu", id], "yabu" => %{id => value}})

  # The handler id a rendered element carries.
  defp click_id(view, selector) do
    [id] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("phx-value-click")

    id
  end

  defp change_id(view, selector) do
    [name] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("name")

    [_, id] = Regex.run(~r/\Ayabu\[(e\d+)\]\z/, name)
    id
  end

  # Commits reach the LiveView over PubSub; wait (bounded) until `check`
  # holds for its render.
  defp eventually(view, check, tries \\ 500) do
    html = render(view)

    cond do
      check.(html) -> html
      tries == 0 -> flunk("never held; last render:\n#{html}")
      true -> eventually(view, check, tries - 1)
    end
  end

  # ---------- serving ----------

  describe "the forum" do
    setup do
      %{u: deploy(@forum, "Forum")}
    end

    test "/ renders the thread list", %{conn: conn, u: u} do
      {view, html} = open(conn, u, "/")
      assert html =~ ~s(id="threads")
      assert has_element?(view, "#threads h1", "Threads")
      assert has_element?(view, "#filter")
    end

    test "the static render serves the app too", %{conn: conn, u: u} do
      html = conn |> on_host(u) |> get("/") |> html_response(200)
      assert html =~ ~s(id="threads")
    end

    test "/post/<uuid> passes the id", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/post/#{@uuid}")
      assert has_element?(view, ~s(#post[data-post="#{@uuid}"]))
    end

    test "a bad param is a 404", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/post/notauuid")
      assert has_element?(view, "#deployment-not-found")
      refute has_element?(view, "#post")
    end

    test "an unknown path is a 404", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/nowhere")
      assert has_element?(view, "#deployment-not-found")
    end

    test "a click and an input change update the model", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/settings")

      change(view, change_id(view, "#name"), "Ada")
      assert has_element?(view, ~s(#name[value="Ada"]))

      click(view, click_id(view, "#save"))
      assert text(view, "#saved") == "Saved"
    end

    test "Cmd.navigate patches to the target app", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      click(view, click_id(view, "#open-settings"))
      assert_patch(view, "/settings")
      assert has_element?(view, "#settings")

      click(view, click_id(view, "#done"))
      assert_patch(view, "/")
      assert has_element?(view, "#threads")
    end

    test "Cmd.navigate with arguments builds the route's URL", %{conn: conn, u: u} do
      assert {:promoted, _} = Universe.stage(u, "jump", @jump)
      {view, _html} = open(conn, u, "/jump/#{@uuid}")

      click(view, click_id(view, "#go"))
      assert_patch(view, "/post/#{@uuid}")
      assert has_element?(view, ~s(#post[data-post="#{@uuid}"]))
    end
  end

  describe "pages" do
    test "an unknown host gets the no-deployment page", %{conn: conn} do
      {:ok, view, _html} = live(%{conn | host: "nobody-here.localhost"}, "/")
      assert has_element?(view, "#no-deployment")
    end

    test "a deployment whose route table does not exist yet", %{conn: conn} do
      u = fresh_universe("dl")
      :ok = Deployment.create(u, u, "Main")
      {view, _html} = open(conn, u, "/")
      assert has_element?(view, "#no-routes")
    end

    test "reserved prefixes never reach the catch-all", %{conn: conn} do
      for path <- ["/_/nothing", "/mcp/x", "/phoenix/x", "/assets/nope.js"] do
        assert conn |> get(path) |> response(404)
      end
    end

    test "/mcp still answers", %{conn: conn} do
      assert conn |> get("/mcp") |> response(405)
    end
  end

  # ---------- the app loop ----------

  describe "the lab" do
    setup do
      %{u: deploy(@lab, "Main")}
    end

    test "random.int and time.now come back as msgs", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")

      click(view, click_id(view, "#roll-dice"))
      html = eventually(view, &(not (&1 =~ ~s(<span id="roll">0</span>))))
      [roll] = Regex.run(~r/<span id="roll">(\d+)<\/span>/, html, capture: :all_but_first)
      assert String.to_integer(roll) in 1..6

      click(view, click_id(view, "#clock"))
      html = eventually(view, &(not (&1 =~ ~s(<span id="now">0</span>))))
      [now] = Regex.run(~r/<span id="now">(\d+)<\/span>/, html, capture: :all_but_first)
      assert_in_delta String.to_integer(now), System.system_time(:millisecond), 60_000
    end

    test "an unsupported effect shows a notice", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      click(view, click_id(view, "#save"))
      assert has_element?(view, "#deployment-notice", "Cmd.store.insert is not available yet")
    end

    test "a runtime error shows a banner and keeps the view", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      click(view, click_id(view, "#inc"))
      assert text(view, "#count") == "1"

      click(view, click_id(view, "#divide"))
      assert has_element?(view, "#deployment-error", "division by zero")
      assert text(view, "#count") == "1"

      # The app keeps running.
      click(view, click_id(view, "#inc"))
      assert text(view, "#count") == "2"
      refute has_element?(view, "#deployment-error")
    end
  end

  describe "events from the browser (Review Focus 2)" do
    setup do
      %{u: deploy(@lab, "Main")}
    end

    test "a forged id is ignored", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      before = render(view)

      for params <- [
            %{"click" => "e999"},
            %{"click" => "Lab.Msg.Inc"},
            %{"click" => %{"x" => 1}},
            %{"click" => ["e0"]},
            %{"yabu_submit" => "e0"},
            %{"_target" => ["yabu", "e0"], "yabu" => %{"e0" => "x"}},
            %{"_target" => ["yabu", "e0"], "yabu" => "clobbered"},
            %{"_target" => "yabu"},
            %{"h" => "e0"},
            %{}
          ] do
        render_click(view, "yabu", params)
      end

      render_click(view, "other", %{"click" => "e0"})
      assert render(view) == before
      assert text(view, "#count") == "0"
    end

    test "an id whose kind does not match the event is ignored", %{conn: conn} do
      u = deploy(@forum, "Forum")
      {view, _html} = open(conn, u, "/settings")
      name = change_id(view, "#name")
      save = click_id(view, "#save")

      # A change id sent as a click, a click id sent as a change.
      click(view, name)
      refute has_element?(view, "#deployment-error")
      change(view, save, "x")
      refute has_element?(view, "#deployment-error")
      assert text(view, "#saved") == ""

      # A change value that is not a string.
      render_change(view, "yabu", %{"_target" => ["yabu", name], "yabu" => %{name => %{"a" => 1}}})

      render_change(view, "yabu", %{"_target" => ["yabu", name], "yabu" => "x"})
      assert has_element?(view, ~s(#name[value=""]))
    end

    test "an id from a stale render only means what the current render says", %{
      conn: conn,
      u: u
    } do
      {view, _html} = open(conn, u, "/")
      inc = click_id(view, "#inc")
      click(view, inc)
      # Re-rendering keeps ids for the same tree, so the old id is still Inc.
      click(view, inc)
      assert text(view, "#count") == "2"
    end
  end

  # ---------- live code ----------

  describe "live code" do
    test "a body change re-renders and keeps the model", %{conn: conn} do
      u = deploy(@lab, "Main")
      {view, _html} = open(conn, u, "/")
      click(view, click_id(view, "#inc"))

      body = String.replace(lab_view(), "Count <span", "Total <span")
      assert {:promoted, _} = Universe.stage(u, "body", body)

      eventually(view, &(&1 =~ "Total"))
      assert text(view, "#count") == "1"
      refute has_element?(view, "#deployment-notice")
    end

    test "a Model change re-inits with a notice", %{conn: conn} do
      u = deploy(@lab, "Main")
      {view, _html} = open(conn, u, "/")
      click(view, click_id(view, "#inc"))

      assert {:promoted, _} = Universe.stage(u, "model", lab_model_v2())

      eventually(view, &(&1 =~ "Model changed; app restarted"))
      assert text(view, "#count") == "0"
    end

    test "a commit that removes the route table gives a 404 (Review Focus 4)", %{conn: conn} do
      u = deploy(@forum, "Forum")
      {view, _html} = open(conn, u, "/settings")
      assert {:promoted, _} = Universe.stage(u, "rm", "", remove: ["Forum"])
      eventually(view, &(&1 =~ ~s(id="deployment-not-found")))
    end

    test "a commit that unroutes the open path gives a 404 (Review Focus 4)", %{
      conn: conn
    } do
      u = deploy(@forum, "Forum")
      {view, _html} = open(conn, u, "/settings")

      routes = """
      defroutes Forum do
        "/" -> Forum.Threads
        "/post/:id" -> Forum.Post
        "/preferences" -> Forum.Settings
      end
      """

      assert {:promoted, _} = Universe.stage(u, "routes", routes)
      eventually(view, &(&1 =~ ~s(id="deployment-not-found")))
      refute has_element?(view, "#settings")
    end

    test "a pinned deployment ignores commits", %{conn: conn} do
      u = deploy(@lab, "Main")
      pinned = "#{u}-pin"
      :ok = Deployment.create(pinned, u, "Main", commit: 1)

      {following, _} = open(conn, u, "/")
      {view, _} = open(conn, pinned, "/")
      click(view, click_id(view, "#inc"))

      body = String.replace(lab_view(), "Count <span", "Total <span")
      assert {:promoted, _} = Universe.stage(u, "body", body)
      eventually(following, &(&1 =~ "Total"))

      html = render(view)
      refute html =~ "Total"
      assert text(view, "#count") == "1"

      # It keeps running its commit's code.
      click(view, click_id(view, "#inc"))
      assert text(view, "#count") == "2"
    end
  end

  defp lab_view do
    [_, view] = String.split(@lab, "def Lab.view", parts: 2)
    [view, _] = String.split(view, "defapp Lab", parts: 2)
    "def Lab.view" <> view
  end

  defp lab_model_v2 do
    """
    defmodel Lab.Model do
      count : Int
      roll : Int
      now : Int
      zero : Int
      label : String
    end

    def Lab.init() : (Lab.Model, Cmd<Lab.Msg>) do
      (%Lab.Model{count: 0, roll: 0, now: 0, zero: 0, label: ""}, Cmd.none())
    end
    """
  end
end
