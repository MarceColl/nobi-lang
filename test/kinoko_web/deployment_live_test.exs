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

  # Two handlers on one element, and a row list keyed by position.
  @rows """
  defmodel P.Model do
    count : Int
    items : List<String>
    log : String
  end

  deftype P.Msg do
    Inc | Dec | Del(String)
  end

  def P.init() : (P.Model, Cmd<P.Msg>) do
    (%P.Model{count: 0, items: ["a", "b", "c", "d"], log: ""}, Cmd.none())
  end

  def P.update(msg : P.Msg, model : P.Model) : (P.Model, Cmd<P.Msg>) do
    case msg do
      P.Msg.Inc -> (%P.Model{model | count: model.count + 1}, Cmd.none())
      P.Msg.Dec -> (%P.Model{model | count: model.count - 100}, Cmd.none())
      P.Msg.Del(x) -> (%P.Model{model | items: List.filter(model.items, fn (i : String) -> i != x end), log: String.concat(model.log, x)}, Cmd.none())
    end
  end

  def P.view(model : P.Model) : Html<P.Msg> do
    <main id="p">
      <span id="count">{model.count}</span>
      <span id="log">{model.log}</span>
      <button id="both" on-click={P.Msg.Inc} on-blur={P.Msg.Dec}>x</button>
      <ul>{List.map(model.items, fn (i : String) -> <li><button id={String.concat("del-", i)} on-click={P.Msg.Del(i)}>{i}</button></li> end)}</ul>
    </main>
  end

  defapp P

  defroutes Main do
    "/" -> P
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

  # A miss answers 404, which `live/2` does not connect from (a browser
  # does): such pages are checked on the static render.
  defp static_404(conn, name, path) do
    conn |> on_host(name) |> get(path) |> html_response(404) |> LazyHTML.from_document()
  end

  defp has?(doc, selector), do: LazyHTML.query(doc, selector) |> Enum.count() > 0

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  # Yabu runs in steps off the LiveView process: an event returns before
  # its step lands, so these wait until no step is in flight.
  defp click(view, id) do
    render_click(view, "yabu:click", %{"click" => id})
    settled(view)
  end

  defp change(view, id, value) do
    render_change(view, "yabu:change", %{"_target" => ["yabu", id], "yabu" => %{id => value}})
    settled(view)
  end

  defp settled(view), do: eventually(view, &(&1 =~ ~s(aria-busy="false")))

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

    [_, id] = Regex.run(~r/\Ayabu\[(r\d+\.e\d+)\]\z/, name)
    id
  end

  # Steps and commits land asynchronously; poll the render until `check`
  # holds, for at most `ms`.
  defp eventually(view, check, ms \\ 5_000),
    do: eventually(view, check, System.monotonic_time(:millisecond) + ms, nil)

  defp eventually(view, check, deadline, _last) do
    html = render(view)

    cond do
      check.(html) ->
        html

      System.monotonic_time(:millisecond) > deadline ->
        flunk("never held; last render:\n#{html}")

      true ->
        receive do
        after
          2 -> eventually(view, check, deadline, html)
        end
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
      doc = static_404(conn, u, "/post/notauuid")
      assert has?(doc, "#kinoko-not-found")
      refute has?(doc, "#post")
    end

    test "an unknown path is a 404", %{conn: conn, u: u} do
      assert conn |> static_404(u, "/nowhere") |> has?("#kinoko-not-found")
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
      eventually(view, &(&1 =~ ~s(id="settings")))

      click(view, click_id(view, "#done"))
      assert_patch(view, "/")
      eventually(view, &(&1 =~ ~s(id="threads")))
    end

    test "Cmd.navigate with arguments builds the route's URL", %{conn: conn, u: u} do
      assert {:promoted, _} = Universe.stage(u, "jump", @jump)
      {view, _html} = open(conn, u, "/jump/#{@uuid}")

      click(view, click_id(view, "#go"))
      assert_patch(view, "/post/#{@uuid}")
      eventually(view, &(&1 =~ ~s(data-post="#{@uuid}")))
    end
  end

  describe "the static render's status" do
    test "a served path is 200, a miss 404, with the page rendered", %{conn: conn} do
      u = deploy(@forum, "Forum")
      assert conn |> on_host(u) |> get("/") |> html_response(200) =~ ~s(id="threads")

      html = conn |> on_host(u) |> get("/post/notauuid") |> html_response(404)
      assert html =~ ~s(id="kinoko-not-found")

      html = %{conn | host: "nobody-here.localhost"} |> get("/") |> html_response(404)
      assert html =~ ~s(id="kinoko-no-deployment")

      empty = fresh_universe("dl")
      :ok = Deployment.create(empty, empty, "Main")
      assert conn |> on_host(empty) |> get("/") |> html_response(404) =~ ~s(id="kinoko-no-routes")
    end
  end

  describe "a deployment that cannot run" do
    test "answers 503 with the unavailable page", %{conn: conn} do
      u = fresh_universe("dl")
      stop(u)
      store_commit(u, "def A.f() : Int do\n  A.nope()\nend")
      :ok = Deployment.create(u, u, "Main")

      ExUnit.CaptureLog.capture_log(fn ->
        html = conn |> on_host(u) |> get("/") |> html_response(503)
        assert html =~ ~s(id="kinoko-unavailable")
      end)
    end
  end

  describe "pages" do
    test "an unknown host gets the no-deployment page", %{conn: conn} do
      assert conn |> static_404("nobody-here", "/") |> has?("#kinoko-no-deployment")
    end

    test "a deployment whose route table does not exist yet", %{conn: conn} do
      u = fresh_universe("dl")
      :ok = Deployment.create(u, u, "Main")
      assert conn |> static_404(u, "/") |> has?("#kinoko-no-routes")
    end

    test "reserved prefixes never reach the catch-all", %{conn: conn} do
      for path <- ["/_/nothing", "/mcp/x", "/phoenix/x", "/assets/nope.js"] do
        assert conn |> get(path) |> response(404)
      end
    end

    test "/mcp still answers", %{conn: conn} do
      assert conn |> get("/mcp") |> response(405)
    end

    test "Kinoko's own pages live under /_", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/_/elm")
      assert {:ok, _view, _html} = live(conn, "/_/sim")
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
      assert has_element?(view, "#kinoko-notice", "Cmd.store.insert is not available yet")
    end

    test "a runtime error shows a banner and keeps the view", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      click(view, click_id(view, "#inc"))
      assert text(view, "#count") == "1"

      click(view, click_id(view, "#divide"))
      assert has_element?(view, "#kinoko-error", "division by zero")
      assert text(view, "#count") == "1"

      # The app keeps running.
      click(view, click_id(view, "#inc"))
      assert text(view, "#count") == "2"
      refute has_element?(view, "#kinoko-error")
    end
  end

  describe "events from the browser (Review Focus 2)" do
    setup do
      %{u: deploy(@lab, "Main")}
    end

    test "a forged id is ignored", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      before = render(view)
      inc = click_id(view, "#inc")
      [_, n] = Regex.run(~r/\Ar(\d+)\./, inc)

      events = ~w(yabu:click yabu:submit yabu:change yabu:blur yabu:keyup yabu:nope yabu yabu:)

      for event <- events,
          params <- [
            %{"click" => "e0"},
            %{"click" => "r#{n}.e999"},
            %{"click" => "r999.e0"},
            %{"click" => "r#{n}.e0x"},
            %{"click" => "r-1.e0"},
            %{"click" => "Lab.Msg.Inc"},
            %{"click" => %{"x" => 1}},
            %{"click" => [inc]},
            %{"blur" => inc},
            %{"yabu_submit" => inc},
            %{"_target" => ["yabu", inc], "yabu" => %{inc => "x"}},
            %{"_target" => ["yabu", inc], "yabu" => "clobbered"},
            %{"_target" => "yabu"},
            %{"h" => inc},
            %{}
          ] do
        render_click(view, event, params)
      end

      render_click(view, "other", %{"click" => inc})
      render_click(view, "yabu", %{"click" => inc})
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
      refute has_element?(view, "#kinoko-error")
      change(view, save, "x")
      refute has_element?(view, "#kinoko-error")
      assert text(view, "#saved") == ""

      # A change value that is not a string.
      render_change(view, "yabu:change", %{
        "_target" => ["yabu", name],
        "yabu" => %{name => %{"a" => 1}}
      })

      render_change(view, "yabu:change", %{"_target" => ["yabu", name], "yabu" => "x"})
      assert has_element?(view, ~s(#name[value=""]))
    end

    test "events while a step is in flight queue up: a double click is two updates", %{
      conn: conn,
      u: u
    } do
      {view, _html} = open(conn, u, "/")
      inc = click_id(view, "#inc")
      render_click(view, "yabu:click", %{"click" => inc})
      render_click(view, "yabu:click", %{"click" => inc})
      render_click(view, "yabu:click", %{"click" => inc})
      eventually(view, &(&1 =~ ~s(<span id="count">3</span>)))
    end

    test "a step result that is not the one in flight is dropped", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      before = render(view)
      send(view.pid, {:stepped, 999, {:ok, %{page: :not_found}}})
      send(view.pid, {:yabu_callback, -1, {:ok, {:var, "Lab.Msg", "Inc", []}}})
      assert render(view) == before
    end

    test "an id resolves in the render it names, until that render is gone", %{
      conn: conn,
      u: u
    } do
      {view, _html} = open(conn, u, "/")
      inc = click_id(view, "#inc")
      click(view, inc)
      assert click_id(view, "#inc") != inc

      # Still kept: the click means what it meant where it was clicked.
      click(view, inc)
      assert text(view, "#count") == "2"

      # Four more renders push it out: then it is ignored.
      for _ <- 1..4, do: click(view, click_id(view, "#inc"))
      assert text(view, "#count") == "6"
      click(view, inc)
      assert text(view, "#count") == "6"
    end

    test "a submit without an id (Enter in a form with no on-submit) is ignored", %{
      conn: conn
    } do
      u = deploy(@forum, "Forum")
      {view, _html} = open(conn, u, "/settings")

      # The on-change input's form submits through LiveView, never natively.
      assert has_element?(view, ~s(form[phx-submit="yabu:submit"] #name))

      before = render(view)
      render_submit(view, "yabu:submit", %{"yabu" => %{change_id(view, "#name") => "x"}})
      assert render(view) == before
    end

    test "on-click and on-blur on one element: each event dispatches its own msg", %{
      conn: conn
    } do
      u = deploy(@rows, "Main")
      {view, _html} = open(conn, u, "/")

      view |> element("#both") |> render_blur()
      settled(view)
      assert text(view, "#count") == "-100"

      view |> element("#both") |> render_click()
      settled(view)
      assert text(view, "#count") == "-99"
    end

    test "two rows clicked before the re-render delete exactly those two", %{conn: conn} do
      u = deploy(@rows, "Main")
      {view, _html} = open(conn, u, "/")
      a = click_id(view, "#del-a")
      b = click_id(view, "#del-b")

      # Both clicks land before either step's render.
      render_click(view, "yabu:click", %{"click" => a})
      render_click(view, "yabu:click", %{"click" => b})
      eventually(view, &(&1 =~ ~s(<span id="log">ab</span>)))
      refute has_element?(view, "#del-a")
      refute has_element?(view, "#del-b")
      assert has_element?(view, "#del-c")
      assert has_element?(view, "#del-d")
    end

    test "the connected view serves the session's deployment, not the URL's host", %{
      conn: conn,
      u: u
    } do
      other = deploy(@forum, "Forum")
      conn = conn |> on_host(u) |> get("/")

      # A client connecting with another host in its URL still gets `u`.
      {:ok, view, _html} = live(%{conn | host: "#{other}.localhost"})
      render(view)
      assert has_element?(view, "#inc")
      refute has_element?(view, "#threads")
    end

    test "the LiveView keeps no timeline (one model per connection)", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      click(view, click_id(view, "#inc"))
      %{socket: socket} = :sys.get_state(view.pid)
      assert Kinoko.Elm.Runtime.timeline(socket.private.elm) == []
    end
  end

  # ---------- update is pure ----------

  describe "update/2" do
    alias KinokoWeb.DeploymentLive

    defp following(head) do
      {m, _} = DeploymentLive.init(%{}, %{})
      d = %{name: "x", universe: "x", routes: "Main", commit: nil, hosts: []}

      %{m | name: "x", deployment: d, target: "x", head: head, subscribed?: true, watching: "x"}
      |> Map.put(:page, :app)
    end

    test "a head that moved since opening is processed as a commit (subscribe race)" do
      {m, fx} = DeploymentLive.update({:head, {:ok, 3}}, following(2))
      assert m.head == 3 and m.inflight == 1 and :queue.to_list(m.queue) == []
      assert [{:async, {:task, _}, _}] = List.flatten([fx])

      {m, fx} = DeploymentLive.update({:head, {:ok, 2}}, following(2))
      assert m.inflight == nil and List.flatten([fx]) == []
    end

    test "msgs arriving during a step wait their turn, commits once" do
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 3}}, following(2))
      assert m.inflight == 1
      {m, fx} = DeploymentLive.update({:committed, "x", %{commit: 4}}, m)
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 5}}, m)
      assert List.flatten([fx]) == [] and :queue.to_list(m.queue) == [:commit]

      # The step lands; the queued commit starts.
      {m, fx} = DeploymentLive.update({:stepped, 1, {:ok, %{}}}, m)
      assert m.inflight == 2 and :queue.to_list(m.queue) == []
      assert [{:async, {:task, _}, _}] = List.flatten([fx])
    end

    test "beyond 32 waiting, events are dropped; control msgs never are" do
      m = %{following(2) | tree: {:text, "x"}}
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 3}}, m)
      assert m.inflight == 1

      m =
        Enum.reduce(1..40, m, fn i, m ->
          elem(DeploymentLive.update({:event, "yabu:click", %{"click" => "r1.e#{i}"}}, m), 0)
        end)

      assert m.queued == 32 and :queue.len(m.queue) == 32

      {m, _} = DeploymentLive.update({:deployment_changed, "x"}, m)
      {m, _} = DeploymentLive.update({:deployment_changed, "x"}, m)
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 4}}, m)
      assert m.queued == 34
      assert Enum.count(:queue.to_list(m.queue), &(&1 == :redeploy)) == 1
    end

    test "a session without a deployment, and the URL's host, never pick one" do
      {m, _} = DeploymentLive.init(%{}, %{"deployment" => "named", "host" => "h"})
      {m, _} = DeploymentLive.update({:params, %{}, "http://evil.localhost/x"}, m)
      assert m.name == "named" and m.host == "h" and m.path == "/x"

      {m, _} = DeploymentLive.init(%{}, %{"deployment" => %{"not" => "a name"}})
      assert m.name == nil
    end

    test "a crashed step shows a generic banner, never the crash" do
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 3}}, following(2))

      {m, _} =
        ExUnit.CaptureLog.with_log(fn ->
          DeploymentLive.update({:stepped, 1, {:error, {:secret, self()}}}, m)
        end)
        |> elem(0)

      assert m.error.code == "internal"
      refute m.error.message =~ "secret"
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
      refute has_element?(view, "#kinoko-notice")
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
      eventually(view, &(&1 =~ ~s(id="kinoko-not-found")))
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
      eventually(view, &(&1 =~ ~s(id="kinoko-not-found")))
      refute has_element?(view, "#settings")
    end

    test "pin and follow reach an open page", %{conn: conn} do
      u = deploy(@lab, "Main")
      {view, _} = open(conn, u, "/")

      body = String.replace(lab_view(), "Count <span", "Total <span")
      assert {:promoted, _} = Universe.stage(u, "body", body)
      eventually(view, &(&1 =~ "Total"))

      :ok = Deployment.pin(u, 1)
      eventually(view, &(&1 =~ "Deployment now serves commit 1"))
      refute render(view) =~ "Total"

      # Pinned: a commit no longer reaches it.
      body3 = String.replace(lab_view(), "Count <span", "Sum <span")
      assert {:promoted, _} = Universe.stage(u, "body3", body3)
      click(view, click_id(view, "#inc"))
      assert text(view, "#count") == "1"
      refute render(view) =~ "Sum"

      :ok = Deployment.follow(u)
      eventually(view, &(&1 =~ "Deployment now follows head"))
      assert render(view) =~ "Sum"

      # Following again: the next commit arrives.
      body4 = String.replace(lab_view(), "Count <span", "Tally <span")
      assert {:promoted, _} = Universe.stage(u, "body4", body4)
      eventually(view, &(&1 =~ "Tally"))
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
