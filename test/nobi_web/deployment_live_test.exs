defmodule NobiWeb.DeploymentLiveTest do
  use NobiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Nobi.UniverseHelpers

  alias Nobi.{Data, Deployment, Universe}

  # Every deployment's data file lands in this test's own directory.
  @moduletag :tmp_dir
  setup %{tmp_dir: dir}, do: isolated_data(dir)

  @forum File.read!("test/fixtures/nobi/forum.nobi")
  @lab File.read!("test/fixtures/nobi/lab.nobi")
  @ticker File.read!("test/fixtures/nobi/ticker.nobi")
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

  # A real link to a route with a param (`Html.href`), and the id as text.
  @hop """
  defmodel Forum.Hop.Model do
    target : Uuid
  end

  deftype Forum.Hop.Msg do
    Noop
  end

  def Forum.Hop.init(id : Uuid) : (Forum.Hop.Model, Cmd<Forum.Hop.Msg>) do
    (%Forum.Hop.Model{target: id}, Cmd.none())
  end

  def Forum.Hop.update(msg : Forum.Hop.Msg, model : Forum.Hop.Model) : (Forum.Hop.Model, Cmd<Forum.Hop.Msg>) do
    (model, Cmd.none())
  end

  def Forum.Hop.view(model : Forum.Hop.Model) : Html<Forum.Hop.Msg> do
    <p>
      <a id="hop" href={Html.href(Forum.Post, model.target)}>{Uuid.to_string(model.target)}</a>
      <a id="nowhere" href={Html.href(Forum.Hop, model.target)}>unrouted</a>
    </p>
  end

  defapp Forum.Hop

  defroutes Forum do
    "/" -> Forum.Threads
    "/post/:id" -> Forum.Post
    "/settings" -> Forum.Settings
    "/hop/:id" -> Forum.Hop
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

  # A stored model with a deftype field and a Result field, written by
  # Cmd.store.insert and Cmd.store.tx and read back by Cmd.store.list.
  @kinds """
  deftype K.Kind do
    A(Int) | B | C(Result<String, Int>)
  end

  defmodel K.Item do
    id : Uuid
    kind : K.Kind
    res : Result<Int, String>
  end

  defmodel K.Model do
    shown : String
  end

  deftype K.Msg do
    Add | Added(Uuid) | Loaded(List<K.Item>) | Bump | Bumped(Result<(List<Uuid>, Int), String>)
  end

  def K.kind(k : K.Kind) : String do
    case k do
      K.Kind.A(n) -> String.concat("A", String.from_int(n))
      K.Kind.B -> "B"
      K.Kind.C(r) ->
        case r do
          Result.Ok(s) -> String.concat("C-ok-", s)
          Result.Err(n) -> String.concat("C-err-", String.from_int(n))
        end
    end
  end

  def K.res(r : Result<Int, String>) : String do
    case r do
      Result.Ok(n) -> String.concat("ok", String.from_int(n))
      Result.Err(e) -> String.concat("err-", e)
    end
  end

  def K.show(i : K.Item) : String do
    String.concat(K.kind(i.kind), String.concat("/", K.res(i.res)))
  end

  def K.init() : (K.Model, Cmd<K.Msg>) do
    (%K.Model{shown: ""}, Cmd.store.list(K.Msg.Loaded))
  end

  def K.update(msg : K.Msg, model : K.Model) : (K.Model, Cmd<K.Msg>) do
    case msg do
      K.Msg.Add -> (model, Cmd.store.insert(%K.Item{kind: K.Kind.C(Result.Err(3)), res: Result.Ok(5)}, K.Msg.Added))
      K.Msg.Added(id) -> (model, Cmd.store.list(K.Msg.Loaded))
      K.Msg.Loaded(rows) -> (%K.Model{shown: String.join(List.map(rows, fn (i : K.Item) -> K.show(i) end), " ")}, Cmd.none())
      K.Msg.Bump ->
        (model,
         Cmd.store.tx(
           fn (s : Store) ->
             ([Tx.insert(%K.Item{kind: K.Kind.A(List.length((Store.list(s) : List<K.Item>))), res: Result.Err("no")})], 0)
           end,
           K.Msg.Bumped))
      K.Msg.Bumped(r) -> (model, Cmd.store.list(K.Msg.Loaded))
    end
  end

  def K.view(model : K.Model) : Html<K.Msg> do
    <main id="k">
      <span id="shown">{model.shown}</span>
      <button id="add" on-click={K.Msg.Add}>Add</button>
      <button id="bump" on-click={K.Msg.Bump}>Bump</button>
    </main>
  end

  defapp K

  defroutes Main do
    "/" -> K
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

  # Nobi runs in steps off the LiveView process: an event returns before
  # its step lands, so these wait until no step is in flight.
  defp click(view, id) do
    render_click(view, "nobi:click", %{"click" => id})
    settled(view)
  end

  defp change(view, id, value) do
    render_change(view, "nobi:change", %{"_target" => ["nobi", id], "nobi" => %{id => value}})
    settled(view)
  end

  # Submits the Nobi form `selector` (its on-submit id is the hidden
  # `nobi_submit` field).
  defp submit(view, selector) do
    [id] =
      view
      |> element(selector <> " input[name=nobi_submit]")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("value")

    render_submit(view, "nobi:submit", %{"nobi_submit" => id})
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

    [_, id] = Regex.run(~r/\Anobi\[(r\d+\.e\d+)\]\z/, name)
    id
  end

  # A model's `Nobi.Data.stats/1` entry in a deployment's file (none: 0 rows).
  defp stat(deployment, model),
    do: Enum.find(Data.stats(deployment), %{rows: 0, columns: []}, &(&1.model == model))

  defp replies(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#replies li")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp wait_for(check, ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn -> check.() end)
    |> Enum.find(fn ok ->
      ok or System.monotonic_time(:millisecond) > deadline or (Process.sleep(5) && false)
    end)
    |> assert()
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

    test "a served app loads the Tailwind runtime, Nobi's console does not", %{conn: conn, u: u} do
      served = conn |> on_host(u) |> get("/") |> html_response(200) |> LazyHTML.from_document()
      assert LazyHTML.query(served, ~s(script[src^="/assets/js/nobi.js"])) |> Enum.count() == 1
      assert LazyHTML.query(served, ~s(script[src^="/assets/js/app.js"])) |> Enum.count() == 1

      console = conn |> get("/_") |> html_response(200) |> LazyHTML.from_document()
      assert LazyHTML.query(console, ~s(script[src^="/assets/js/nobi.js"])) |> Enum.count() == 0
      assert LazyHTML.query(console, ~s(script[src^="/assets/js/app.js"])) |> Enum.count() == 1
    end

    test "/post/<uuid> passes the id", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/post/#{@uuid}")
      assert has_element?(view, ~s(#post[data-post="#{@uuid}"]))
    end

    test "a bad param is a 404", %{conn: conn, u: u} do
      doc = static_404(conn, u, "/post/notauuid")
      assert has?(doc, "#nobi-not-found")
      refute has?(doc, "#post")
    end

    test "an unknown path is a 404", %{conn: conn, u: u} do
      assert conn |> static_404(u, "/nowhere") |> has?("#nobi-not-found")
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

  describe "links (Html.href)" do
    setup do
      u = deploy(@forum, "Forum")
      assert {:promoted, _} = Universe.stage(u, "hop", @hop)
      %{u: u}
    end

    test "render a real href to the route, patched by LiveView", %{conn: conn, u: u} do
      doc =
        conn
        |> on_host(u)
        |> get("/hop/#{@uuid}")
        |> html_response(200)
        |> LazyHTML.from_document()

      [hop] = doc |> LazyHTML.query("a#hop") |> Enum.to_list()
      assert LazyHTML.attribute(hop, "href") == ["/post/#{@uuid}"]
      assert LazyHTML.attribute(hop, "data-phx-link") == ["patch"]
      assert LazyHTML.text(hop) == @uuid

      # A link to the app's own route.
      [self] = doc |> LazyHTML.query("a#nowhere") |> Enum.to_list()
      assert LazyHTML.attribute(self, "href") == ["/hop/#{@uuid}"]
    end

    test "a click navigates inside the LiveView", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/hop/#{@uuid}")
      view |> element("a#hop") |> render_click()
      assert_patch(view, "/post/#{@uuid}")
      eventually(view, &(&1 =~ ~s(data-post="#{@uuid}")))
    end

    test "a link goes to the first route that reaches it, and without one has no href", %{
      conn: conn,
      u: u
    } do
      assert {:promoted, _} =
               Universe.stage(u, "unroute", """
               defroutes Forum do
                 "/" -> Forum.Threads
                 "/post/:id" -> Forum.Post
                 "/settings" -> Forum.Settings
                 "/hop/:id" -> Forum.Hop
                 "/jump/:id" -> Forum.Hop
               end
               """)

      # Two routes to Forum.Hop: the first wins, so a link to it is /hop/<id>.
      {view, _html} = open(conn, u, "/jump/#{@uuid}")
      assert has_element?(view, ~s(a#nowhere[href="/hop/#{@uuid}"]))

      assert {:promoted, _} =
               Universe.stage(u, "unroute", """
               defroutes Forum do
                 "/" -> Forum.Threads
                 "/jump/:id" -> Forum.Hop
               end
               """)

      {view, _html} = open(conn, u, "/jump/#{@uuid}")
      assert has_element?(view, "a#hop")
      refute has_element?(view, "a#hop[href]")
    end
  end

  describe "the static render's status" do
    test "a served path is 200, a miss 404, with the page rendered", %{conn: conn} do
      u = deploy(@forum, "Forum")
      assert conn |> on_host(u) |> get("/") |> html_response(200) =~ ~s(id="threads")

      html = conn |> on_host(u) |> get("/post/notauuid") |> html_response(404)
      assert html =~ ~s(id="nobi-not-found")

      html = %{conn | host: "nobody-here.localhost"} |> get("/") |> html_response(404)
      assert html =~ ~s(id="nobi-no-deployment")

      empty = fresh_universe("dl")
      :ok = Deployment.create(empty, empty, "Main")
      assert conn |> on_host(empty) |> get("/") |> html_response(404) =~ ~s(id="nobi-no-routes")
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
        assert html =~ ~s(id="nobi-unavailable")
      end)
    end
  end

  describe "pages" do
    test "an unknown host gets the no-deployment page", %{conn: conn} do
      assert conn |> static_404("nobody-here", "/") |> has?("#nobi-no-deployment")
    end

    test "a deployment whose route table does not exist yet", %{conn: conn} do
      u = fresh_universe("dl")
      :ok = Deployment.create(u, u, "Main")
      assert conn |> static_404(u, "/") |> has?("#nobi-no-routes")
    end

    test "reserved prefixes never reach the catch-all", %{conn: conn} do
      for path <- ["/_/nothing", "/mcp/x", "/phoenix/x", "/assets/nope.js"] do
        assert conn |> get(path) |> response(404)
      end
    end

    test "/mcp still answers", %{conn: conn} do
      assert conn |> get("/mcp") |> response(405)
    end

    test "Nobi's own pages live under /_", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/_/elm")
      assert {:ok, _view, _html} = live(conn, "/_/sim")
    end
  end

  # ---------- stored data ----------

  describe "stored data" do
    setup do
      %{u: deploy(@forum, "Forum")}
    end

    test "a thread and its replies, created through the UI, survive a remount", %{
      conn: conn,
      u: u
    } do
      {view, _html} = open(conn, u, "/")
      refute has_element?(view, "#topics li")

      change(view, change_id(view, "#title"), "Hello")
      submit(view, "#new-thread")
      "/post/" <> id = path = assert_patch(view, 5_000)
      eventually(view, fn _ -> has_element?(view, "#post-title", "Hello") end)
      assert has_element?(view, ~s(#post[data-post="#{id}"]))
      assert text(view, "#reply-count") == "0"

      for {body, n} <- [{"first!", "1"}, {"second", "2"}] do
        change(view, change_id(view, "#draft"), body)
        submit(view, "#reply-form")
        eventually(view, fn _ -> text(view, "#reply-count") == n end)
      end

      assert replies(view) == ["first!", "second"]
      refute has_element?(view, "#nobi-error")

      # A new connection reads it all back from storage.
      {again, _html} = open(conn, u, path)
      assert text(again, "#post-title") == "Hello"
      assert text(again, "#reply-count") == "2"
      assert replies(again) == ["first!", "second"]

      {threads, _html} = open(conn, u, "/")
      assert text(threads, "#topics li") =~ "Hello"
      assert text(threads, "#topics li span") == "2"
    end

    test "two deployments of one universe have separate data", %{conn: conn, u: u} do
      other = "#{u}-b"
      :ok = Deployment.create(other, u, "Forum")

      {view, _html} = open(conn, u, "/")
      change(view, change_id(view, "#title"), "Only here")
      submit(view, "#new-thread")
      assert "/post/" <> _ = assert_patch(view, 5_000)

      {mine, _html} = open(conn, u, "/")
      assert text(mine, "#topics li") =~ "Only here"

      {theirs, _html} = open(conn, other, "/")
      refute has_element?(theirs, "#topics li")
      assert stat(u, "Forum.Topic").rows == 1
      assert stat(other, "Forum.Topic").rows == 0
    end

    test "a pinned older commit reads rows newer code wrote (Review Focus 3)", %{
      conn: conn,
      u: u
    } do
      # Commit 2 adds a column to Forum.Topic.
      v2 =
        @forum
        |> String.replace(
          "  replies : Int = 0\n",
          "  replies : Int = 0\n  pinned : Bool = false\n"
        )
        |> String.replace("replies: 0}", "replies: 0, pinned: true}")

      assert {:promoted, _} = Universe.stage(u, "v2", v2)

      {view, _html} = open(conn, u, "/")
      change(view, change_id(view, "#title"), "From v2")
      submit(view, "#new-thread")
      assert "/post/" <> _ = assert_patch(view, 5_000)

      assert "pinned" in Enum.map(stat(u, "Forum.Topic").columns, & &1.name)

      # Back to commit 1, whose Forum.Topic has no `pinned`: the row reads.
      :ok = Deployment.pin(u, 1)
      {old, _html} = open(conn, u, "/")
      assert text(old, "#topics li") =~ "From v2"
      refute has_element?(old, "#nobi-error")

      # And old code still writes: the newer column is left to its default.
      change(old, change_id(old, "#title"), "From v1")
      submit(old, "#new-thread")
      assert "/post/" <> _ = assert_patch(old, 5_000)
      assert stat(u, "Forum.Topic").rows == 2

      # The head (v2) reads v1's row with the new field's default.
      {:ok, image} = Universe.image(u)
      {:ok, repo} = Data.open(u)
      {:ok, rows} = Data.list(repo, "Forum.Topic", image.module.__nobi__(:models))
      pinned = Map.new(rows, fn {:rec, _, f} -> {f["title"], f["pinned"]} end)
      assert pinned == %{"From v2" => true, "From v1" => false}
    end

    @tag :capture_log
    test "a row storage cannot read: the banner, or tx's Err", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      change(view, change_id(view, "#title"), "Soon broken")
      submit(view, "#new-thread")
      assert "/post/" <> _ = path = assert_patch(view, 5_000)

      {:ok, repo} = Data.open(u)
      Data.Repo.put_dynamic_repo(repo)
      Data.Repo.query!("UPDATE forum__topic SET replies = 'many'")

      {broken, _html} = open(conn, u, "/")
      assert has_element?(broken, "#nobi-error", "store")
      assert has_element?(broken, "#nobi-error", "Forum.Topic")
      # The stored value is never shown.
      refute has_element?(broken, "#nobi-error", "many")
      assert has_element?(broken, "#threads")

      # A transaction reports through its callback instead: no banner.
      {post, _html} = open(conn, u, path)
      assert has_element?(post, "#nobi-error", "store")
      render_click(post, "dismiss", %{})
      change(post, change_id(post, "#draft"), "hello?")
      submit(post, "#reply-form")
      eventually(post, fn _ -> has_element?(post, "#post-error", "Forum.Topic") end)
      refute has_element?(post, "#nobi-error")
      assert stat(u, "Forum.Reply").rows == 0
    end
  end

  describe "store errors the browser sees" do
    setup do
      %{u: deploy(@forum, "Forum")}
    end

    test "SQLite's own words never reach the banner or a tx's Err", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      change(view, change_id(view, "#title"), "Dup")
      submit(view, "#new-thread")
      assert "/post/" <> _ = path = assert_patch(view, 5_000)

      {:ok, repo} = Data.open(u)
      {:ok, image} = Universe.image(u)
      :ok = Data.ensure(repo, "Forum.Reply", image.module.__nobi__(:models))
      Data.Repo.put_dynamic_repo(repo)
      Data.Repo.query!(~s[CREATE UNIQUE INDEX one_title ON "forum__topic" ("title")])
      Data.Repo.query!(~s[CREATE UNIQUE INDEX one_body ON "forum__reply" ("body")])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {view, _html} = open(conn, u, "/")
          change(view, change_id(view, "#title"), "Dup")
          submit(view, "#new-thread")
          eventually(view, &(&1 =~ ~s(id="nobi-error")))
          assert has_element?(view, "#nobi-error", "the store rejected the operation")
          refute render(view) =~ "UNIQUE"

          {post, _html} = open(conn, u, path)

          for _ <- 1..2 do
            change(post, change_id(post, "#draft"), "same")
            submit(post, "#reply-form")
          end

          eventually(post, fn _ ->
            has_element?(post, "#post-error", "the store rejected the operation")
          end)

          refute render(post) =~ "UNIQUE"
          refute has_element?(post, "#nobi-error")
        end)

      assert log =~ "UNIQUE constraint failed"
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
      click(view, click_id(view, "#stash"))
      assert has_element?(view, "#nobi-notice", "Cmd.blob.put is not available yet")
    end

    test "a store effect runs: no notice, and the row is stored", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      click(view, click_id(view, "#save"))
      wait_for(fn -> match?([%{model: "Lab.Note", rows: 1}], Data.stats(u)) end)
      refute has_element?(view, "#nobi-notice")
      refute has_element?(view, "#nobi-error")
    end

    test "a runtime error shows a banner and keeps the view", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      click(view, click_id(view, "#inc"))
      assert text(view, "#count") == "1"

      click(view, click_id(view, "#divide"))
      assert has_element?(view, "#nobi-error", "division by zero")
      assert text(view, "#count") == "1"

      # The app keeps running.
      click(view, click_id(view, "#inc"))
      assert text(view, "#count") == "2"
      refute has_element?(view, "#nobi-error")
    end
  end

  describe "timers (Cmd.time.after)" do
    alias Nobi.Elm.Sim
    alias NobiWeb.DeploymentLive

    setup do
      %{u: deploy(@ticker, "Main")}
    end

    defp count(%{model: {:rec, "Ticker.Model", %{"count" => n}}}), do: n
    defp count(_m), do: 0

    test "a loop that re-arms its timer counts on its own, once connected", %{conn: conn, u: u} do
      # The static render starts no timer.
      static = conn |> on_host(u) |> get("/") |> html_response(200)
      assert static =~ ~s(<span id="count">0</span>)

      {view, _html} = open(conn, u, "/")
      eventually(view, &(&1 =~ ~s(<span id="count">3</span>)))
      refute has_element?(view, "#nobi-error")
    end

    test "the earliest timer fires first", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      eventually(view, &(&1 =~ ~s(<span id="count">3</span>)))
      click(view, click_id(view, "#race"))
      eventually(view, &(&1 =~ ~s(<span id="log">early-tie,late</span>)))
    end

    test "under Nobi.Elm.Sim each tick arrives on virtual time, the same on every walk", %{
      u: u
    } do
      spec = %{
        module: DeploymentLive,
        init: fn ->
          {m, fx} = DeploymentLive.init(%{}, %{"deployment" => u, "elm_connected?" => true})
          {m, open} = DeploymentLive.update({:params, %{}, "http://#{u}.localhost/"}, m)
          {m, [fx, open]}
        end,
        # Steps really run (they read the deployment); time is the simulator's.
        outcomes: fn
          {:task, fun}, _clock -> [{"ran", {:ok, fun.()}}]
          _request, _clock -> nil
        end,
        invariants: [{"no tick before its time", fn m, world -> count(m) * 10 <= world.clock end}]
      }

      walks = for seed <- 1..3, do: Sim.run(spec, seed)
      [walk | _] = walks

      assert walk.violation == nil
      last = List.last(walk.trace)
      assert count(last.state) == 3 and last.clock == 30 and last.state.error == nil

      fired = for %{label: "⏱ t=" <> rest} <- walk.trace, do: Integer.parse(rest) |> elem(0)
      assert fired == [10, 20, 30]

      labels = &Enum.map(&1.trace, fn node -> node.label end)
      assert Enum.all?(walks, &(labels.(&1) == labels.(walk)))
    end
  end

  describe "WASM (Cmd.wasm.call)" do
    setup do
      %{u: deploy(Nobi.WasmFixture.app(Nobi.WasmFixture.put!()), "W.Routes")}
    end

    test "the static render never runs WASM; the connected mount does", %{conn: conn, u: u} do
      static = conn |> on_host(u) |> get("/") |> html_response(200)
      assert static =~ ~s(<p id="out"></p>)
      assert static =~ ~s(<p id="dps">0.0</p>)

      {view, _html} = open(conn, u, "/")
      html = eventually(view, &(&1 =~ ~s(<p id="dps">7.25</p>)))
      assert html =~ ~s(<p id="runs">1</p>)
    end

    test "a loop calls, decodes the Float and re-arms with a timer", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      eventually(view, &(&1 =~ ~s(<p id="runs">1</p>)))
      click(view, click_id(view, "#start"))
      html = eventually(view, &(&1 =~ ~s(<p id="runs">4</p>)))
      assert html =~ ~s(<p id="dps">1234.5</p>)
      refute has_element?(view, "#nobi-error")
    end

    test "a runaway call ends as Err while the page keeps updating", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      eventually(view, &(&1 =~ ~s(<p id="runs">1</p>)))

      click(view, click_id(view, "#spin"))
      click(view, click_id(view, "#click"))
      # The click is handled while `spin` burns its fuel (about 0.2 s here).
      assert text(view, "#clicks") == "1"
      refute text(view, "#errs") =~ "out of fuel"

      eventually(view, &(&1 =~ ~s(<p id="errs">out of fuel</p>)))
      refute has_element?(view, "#nobi-error")
    end

    test "past 4 calls in flight a call gets Err at once", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      eventually(view, &(&1 =~ ~s(<p id="runs">1</p>)))
      click(view, click_id(view, "#burst"))

      errs = fn html ->
        [errs] = Regex.run(~r/<p id="errs">([^<]*)<\/p>/, html, capture: :all_but_first)
        String.split(errs, ";", trim: true)
      end

      html = eventually(view, &(length(errs.(&1)) == 5))

      assert errs.(html) |> Enum.frequencies() ==
               %{"too many wasm calls in flight" => 1, "out of fuel" => 4}
    end
  end

  describe "deftype and Result fields" do
    test "are stored by insert and tx and read back exactly", %{conn: conn} do
      u = deploy(@kinds, "Main")
      {view, _html} = open(conn, u, "/")
      settled(view)

      click(view, click_id(view, "#add"))
      eventually(view, &(&1 =~ ~s(<span id="shown">C-err-3/ok5</span>)))

      click(view, click_id(view, "#bump"))
      eventually(view, &(&1 =~ ~s(<span id="shown">C-err-3/ok5 A1/err-no</span>)))
      refute has_element?(view, "#nobi-error")

      # A fresh mount reads them from the store.
      {view, _html} = open(conn, u, "/")
      eventually(view, &(&1 =~ ~s(<span id="shown">C-err-3/ok5 A1/err-no</span>)))
    end
  end

  describe "events from the browser (Review Focus 2)" do
    setup do
      %{u: deploy(@lab, "Main")}
    end

    test "a forged id is ignored", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      # Snapshot only once nothing is in flight (init's own effects).
      before = settled(view)
      inc = click_id(view, "#inc")
      [_, n] = Regex.run(~r/\Ar(\d+)\./, inc)

      events = ~w(nobi:click nobi:submit nobi:change nobi:blur nobi:keyup nobi:nope nobi nobi:)

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
            %{"nobi_submit" => inc},
            %{"_target" => ["nobi", inc], "nobi" => %{inc => "x"}},
            %{"_target" => ["nobi", inc], "nobi" => "clobbered"},
            %{"_target" => "nobi"},
            %{"h" => inc},
            %{}
          ] do
        render_click(view, event, params)
      end

      render_click(view, "other", %{"click" => inc})
      render_click(view, "nobi", %{"click" => inc})
      assert settled(view) == before
      assert text(view, "#count") == "0"
    end

    test "an id whose kind does not match the event is ignored", %{conn: conn} do
      u = deploy(@forum, "Forum")
      {view, _html} = open(conn, u, "/settings")
      name = change_id(view, "#name")
      save = click_id(view, "#save")

      # A change id sent as a click, a click id sent as a change.
      click(view, name)
      refute has_element?(view, "#nobi-error")
      change(view, save, "x")
      refute has_element?(view, "#nobi-error")
      assert text(view, "#saved") == ""

      # A change value that is not a string.
      render_change(view, "nobi:change", %{
        "_target" => ["nobi", name],
        "nobi" => %{name => %{"a" => 1}}
      })

      render_change(view, "nobi:change", %{"_target" => ["nobi", name], "nobi" => "x"})
      assert has_element?(view, ~s(#name[value=""]))
    end

    test "events while a step is in flight queue up: a double click is two updates", %{
      conn: conn,
      u: u
    } do
      {view, _html} = open(conn, u, "/")
      inc = click_id(view, "#inc")
      render_click(view, "nobi:click", %{"click" => inc})
      render_click(view, "nobi:click", %{"click" => inc})
      render_click(view, "nobi:click", %{"click" => inc})
      eventually(view, &(&1 =~ ~s(<span id="count">3</span>)))
    end

    test "a step result that is not the one in flight is dropped", %{conn: conn, u: u} do
      {view, _html} = open(conn, u, "/")
      before = settled(view)
      send(view.pid, {:stepped, 999, {:ok, %{page: :not_found}}})
      send(view.pid, {:nobi_callback, -1, {:ok, {:var, "Lab.Msg", "Inc", []}}})
      assert settled(view) == before
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
      assert has_element?(view, ~s(form[phx-submit="nobi:submit"] #name))

      before = settled(view)
      render_submit(view, "nobi:submit", %{"nobi" => %{change_id(view, "#name") => "x"}})
      assert settled(view) == before
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
      render_click(view, "nobi:click", %{"click" => a})
      render_click(view, "nobi:click", %{"click" => b})
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
      assert Nobi.Elm.Runtime.timeline(socket.private.elm) == []
    end
  end

  # ---------- update is pure ----------

  describe "update/2" do
    alias NobiWeb.DeploymentLive

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
          elem(DeploymentLive.update({:event, "nobi:click", %{"click" => "r1.e#{i}"}}, m), 0)
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

    test "a store effect whose model never settled shows a banner, and runs nothing" do
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 3}}, following(2))
      cmd = {:cmd, {:effect, "Cmd.store.list", nil, [fn rows -> rows end]}}
      {m, fx} = DeploymentLive.update({:stepped, 1, {:ok, %{cmd: cmd}}}, m)
      assert m.error.code == "host"
      assert m.error.message =~ "Cmd.store.list"
      assert m.error.message =~ "never settled"
      refute Enum.any?(List.flatten([fx]), &match?({:async, {:task, _}, _}, &1))
    end

    test "a store task in flight counts as busy until its result arrives" do
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 3}}, following(2))
      cmd = {:cmd, {:effect, "Cmd.store.list", "X.Row", [fn rows -> rows end]}}
      {m, fx} = DeploymentLive.update({:stepped, 1, {:ok, %{cmd: cmd}}}, m)
      assert m.storing == 1 and DeploymentLive.busy?(m)
      assert Enum.any?(List.flatten([fx]), &match?({:async, {:task, _}, _}, &1))

      # Even a result for a replaced mount ends the wait.
      {m, _} = DeploymentLive.update({:stored, -1, {:ok, :msg}}, m)
      assert m.storing == 0 and not DeploymentLive.busy?(m)
    end

    test "a timer is Effect.after_ms, kept past a full queue, dropped for a replaced mount" do
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 3}}, following(2))
      cmd = {:cmd, {:effect, "Cmd.time.after", nil, [10, :tick]}}
      {m, fx} = DeploymentLive.update({:stepped, 1, {:ok, %{cmd: cmd}}}, m)
      gen = m.gen

      assert {:after_ms, 10, {:nobi_callback, ^gen, {:ok, :tick}, :keep} = fired} =
               Enum.find(List.flatten([fx]), &match?({:after_ms, _, _}, &1))

      # A step in flight and 32 events waiting: a plain callback is dropped,
      # the timer's msg waits its turn.
      m = %{m | tree: {:text, "x"}}
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 4}}, m)

      m =
        Enum.reduce(1..32, m, fn i, m ->
          elem(DeploymentLive.update({:event, "nobi:click", %{"click" => "r1.e#{i}"}}, m), 0)
        end)

      {m, _} = DeploymentLive.update({:nobi_callback, gen, {:ok, :lost}}, m)
      assert m.queued == 32
      {m, _} = DeploymentLive.update(fired, m)
      assert m.queued == 33
      assert {:value, {:callback, ^gen, {:ok, :tick}, :keep}} = :queue.peek_r(m.queue)

      # Idle: the current mount's timer starts a step, an older mount's does not.
      idle = %{m | inflight: nil, queue: :queue.new(), queued: 0}
      {stale, _} = DeploymentLive.update({:nobi_callback, gen - 1, {:ok, :tick}, :keep}, idle)
      assert stale.inflight == nil
      {live, _} = DeploymentLive.update(fired, idle)
      assert live.inflight == idle.seq + 1
    end

    test "a timer out of range shows a banner and starts nothing" do
      {m, _} = DeploymentLive.update({:committed, "x", %{commit: 3}}, following(2))
      cmd = {:cmd, {:effect, "Cmd.time.after", nil, [-1, :tick]}}
      {m, fx} = DeploymentLive.update({:stepped, 1, {:ok, %{cmd: cmd}}}, m)
      assert m.error.message =~ "Cmd.time.after: ms must be 0..86400000"
      refute Enum.any?(List.flatten([fx]), &match?({:after_ms, _, _}, &1))
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
      refute has_element?(view, "#nobi-notice")
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
      eventually(view, &(&1 =~ ~s(id="nobi-not-found")))
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
      eventually(view, &(&1 =~ ~s(id="nobi-not-found")))
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
