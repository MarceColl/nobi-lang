defmodule NobiWeb.McpSendTest do
  # `send` writes deployments' data files: not async.
  use NobiWeb.ConnCase, async: false

  import Nobi.UniverseHelpers

  alias Nobi.{Data, Deployment, Universe}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir}, do: isolated_data(dir)

  @board """
  defmodel B.Post do
    id : Uuid
    title : String
    votes : Int
  end

  defmodel B.Model do
    draft : String
    posts : List<B.Post>
    note : String
  end

  deftype B.Msg do
    Draft(String) | Post | Saved(Uuid) | Loaded(List<B.Post>) | Bump | Bumped(Result<(List<Uuid>, Int), String>) | Spin | Tick(Int) | Stash | Stashed(String) | Go | Burst
  end

  def B.init() : (B.Model, Cmd<B.Msg>) do
    (%B.Model{draft: "", posts: [], note: ""}, Cmd.store.list(B.Msg.Loaded))
  end

  def B.update(msg : B.Msg, model : B.Model) : (B.Model, Cmd<B.Msg>) do
    case msg do
      B.Msg.Draft(s) -> (%B.Model{model | draft: s}, Cmd.none())
      B.Msg.Post -> (%B.Model{model | draft: ""}, Cmd.store.insert(%B.Post{title: model.draft, votes: 0}, B.Msg.Saved))
      B.Msg.Saved(id) -> (model, Cmd.store.list(B.Msg.Loaded))
      B.Msg.Loaded(rows) -> (%B.Model{model | posts: rows}, Cmd.none())
      B.Msg.Bump ->
        (model,
         Cmd.store.tx(
           fn (s : Store) ->
             ([Tx.insert(%B.Post{title: String.concat("tx-", String.from_int(List.length((Store.list(s) : List<B.Post>)))), votes: 1})], 7)
           end,
           B.Msg.Bumped))
      B.Msg.Bumped(r) ->
        case r do
          Result.Ok(pair) -> (%B.Model{model | note: "bumped"}, Cmd.store.list(B.Msg.Loaded))
          Result.Err(e) -> (%B.Model{model | note: e}, Cmd.none())
        end
      B.Msg.Spin -> (model, Cmd.time.now(B.Msg.Tick))
      B.Msg.Tick(t) -> (model, Cmd.time.now(B.Msg.Tick))
      B.Msg.Stash -> (model, Cmd.blob.put("k", "v", B.Msg.Stashed))
      B.Msg.Stashed(k) -> (model, Cmd.none())
      B.Msg.Go -> (model, Cmd.navigate(B.Show, "x"))
      B.Msg.Burst -> (model, Cmd.batch(List.map([#{Enum.join(1..60, ", ")}], fn (i : Int) -> Cmd.blob.put("k", String.from_int(i), B.Msg.Stashed) end)))
    end
  end

  def B.view(model : B.Model) : Html<B.Msg> do
    <main>
      <h1>Board {model.note}</h1>
      <ul>{List.map(model.posts, fn (p : B.Post) -> <li><a href={Html.href(B.Show, Uuid.to_string(p.id))}>{p.title}</a></li> end)}</ul>
    </main>
  end

  defapp B

  defmodel B.Show.Model do
    key : String
  end

  deftype B.Show.Msg do
    Noop
  end

  def B.Show.init(key : String) : (B.Show.Model, Cmd<B.Show.Msg>) do
    (%B.Show.Model{key: key}, Cmd.none())
  end

  def B.Show.update(msg : B.Show.Msg, model : B.Show.Model) : (B.Show.Model, Cmd<B.Show.Msg>) do
    (model, Cmd.none())
  end

  def B.Show.view(model : B.Show.Model) : Html<B.Show.Msg> do
    <p>{model.key}</p>
  end

  defapp B.Show

  defroutes B.Routes do
    "/" -> B
    "/p/:key" -> B.Show
  end
  """

  @ticker File.read!("test/fixtures/nobi/ticker.nobi")

  # ---------- helpers ----------

  defp call(conn, args) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "send", "arguments" => args}
    }

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", Jason.encode!(msg))

    %{"result" => %{"content" => [%{"text" => text}], "isError" => error?}} =
      Jason.decode!(conn.resp_body)

    {text, error?}
  end

  defp send!(conn, d, path, messages) do
    {text, false} = call(conn, %{"deployment" => d, "path" => path, "messages" => messages})
    text
  end

  defp send_err!(conn, d, path, messages) do
    {text, true} = call(conn, %{"deployment" => d, "path" => path, "messages" => messages})
    text
  end

  defp rows(d, u) do
    {:ok, repo} = Data.open(d)
    {:ok, image} = Universe.image(u)
    models = %{models: image.module.__nobi__(:models), types: image.module.__nobi__(:types)}
    {:ok, rows} = Data.list(repo, "B.Post", models)
    Enum.map(rows, fn {:rec, "B.Post", fields} -> fields["title"] end)
  end

  setup do
    u = fresh_universe("send")
    assert {:promoted, _} = Universe.stage(u, "board", @board)
    :ok = Deployment.create(u, u, "B.Routes", [])
    %{d: u, u: u}
  end

  # ---------- tests ----------

  test "messages that insert a row write the deployment's data", %{conn: conn, d: d, u: u} do
    text = send!(conn, d, "/", [~s|B.Msg.Draft("hello world")|, "B.Msg.Post"])

    assert text =~ "send: #{d} / -> B."
    assert text =~ "[init]\n  Cmd.store.list(B.Post) -> [] => B.Msg.Loaded([])"
    assert text =~ ~s|[send] B.Msg.Draft("hello world")\n  no effects|
    assert text =~ ~r/Cmd.store.insert\(B.Post\) -> <uuid [0-9a-f-]{36}> => B.Msg.Saved\(<uuid/
    assert text =~ "Cmd.store.list(B.Post) -> [%B.Post{"
    assert text =~ "final model: %B.Model{"
    assert rows(d, u) == ["hello world"]

    # What a user would see now: the new row, as a real link.
    assert [_, view] = String.split(text, "view text: ")
    assert view =~ "Board hello world"
    assert view =~ ~r|view links: /p/[0-9a-f-]{36} \(hello world\)|

    # The data persists: a second run reads it back.
    assert send!(conn, d, "/", []) =~ "Cmd.store.list(B.Post) -> [%B.Post{"
  end

  test "a tx runs and its callback gets Ok", %{conn: conn, d: d, u: u} do
    text = send!(conn, d, "/", ["B.Msg.Bump"])
    assert text =~ "Cmd.store.tx -> Result.Ok(([<uuid"
    assert text =~ ~s|note: "bumped"|
    assert rows(d, u) == ["tx-0"]
  end

  test "a message that does not check runs nothing, and says why", %{conn: conn, d: d, u: u} do
    text = send_err!(conn, d, "/", [~s|B.Msg.Draft("a")|, "B.Msg.Nope", "B.Msg.Post"])
    assert text =~ "message 2 `B.Msg.Nope` is not a B.Msg"
    assert text =~ "Nothing ran"

    assert send_err!(conn, d, "/", ["42"]) =~ "message 1 `42` is not a B.Msg"
    assert send_err!(conn, d, "/", ["B.Msg.Draft(1)"]) =~ "message 1"
    assert rows(d, u) == []
  end

  test "an unknown path or deployment is an error that says what exists", %{conn: conn, d: d} do
    text = send_err!(conn, d, "/nowhere", [])
    assert text =~ ~s|no route in B.Routes matches "/nowhere"|
    assert text =~ "/p/:key -> B.Show"

    assert send_err!(conn, "nope-#{System.unique_integer([:positive])}", "/", []) =~
             "no deployment named"

    assert send!(conn, d, "/p/abc", []) =~ "-> B.Show(\"abc\")"
  end

  test "a callback loop stops at the step cap", %{conn: conn, d: d} do
    text = send_err!(conn, d, "/", ["B.Msg.Spin", "B.Msg.Post"])
    assert text =~ "step cap reached: 50 effects"
    assert text =~ "Cmd.time.now -> "
    # The run stops there: the next message never runs.
    refute text =~ "[send] B.Msg.Post"
  end

  test "an effect that cannot run is an error; navigate is reported, not followed", %{
    conn: conn,
    d: d
  } do
    assert send_err!(conn, d, "/", ["B.Msg.Stash"]) =~
             "Cmd.blob.put -> ERROR: Cmd.blob.put is not available yet"

    assert send!(conn, d, "/", ["B.Msg.Go"]) =~
             "Cmd.navigate(B.Show) -> /p/x (a page would go to /p/x; send stays here)"
  end

  test "the tool and the instructions say plainly that send writes real data" do
    [tool] = Enum.filter(NobiWeb.Mcp.Tools.list(), &(&1.name == "send"))
    assert tool.description =~ "WRITES THE DEPLOYMENT'S REAL DATA"
    assert tool.inputSchema.required == ["deployment", "path"]
    assert NobiWeb.Mcp.Instructions.head() =~ "WRITES that deployment's data"
    assert NobiWeb.Mcp.Instructions.text() =~ "ON THAT DEPLOYMENT'S REAL DATA"
  end

  describe "timers (Cmd.time.after)" do
    setup do
      t = fresh_universe("tick")
      assert {:promoted, _} = Universe.stage(t, "ticker", @ticker)
      :ok = Deployment.create(t, t, "Main", [])
      %{t: t}
    end

    test "fire on a virtual clock, at once, each counting as an effect", %{conn: conn, t: t} do
      text = send!(conn, t, "/", [])

      assert text =~
               "[init]\n" <>
                 "  Cmd.time.after(10) -> fired at 10ms => Ticker.Msg.Tick (virtual time, after 10ms)\n" <>
                 "  Cmd.time.after(10) -> fired at 20ms => Ticker.Msg.Tick (virtual time, after 10ms)\n" <>
                 "  Cmd.time.after(10) -> fired at 30ms => Ticker.Msg.Tick (virtual time, after 10ms)\n"

      assert text =~ "view text: Count 3"
    end

    test "the earliest fires first; equal ones in the order issued", %{conn: conn, t: t} do
      text = send!(conn, t, "/", ["Ticker.Msg.Race"])
      assert text =~ "fired at 35ms => Ticker.Msg.Mark(\"early\")"
      assert text =~ "fired at 50ms => Ticker.Msg.Mark(\"late\")"
      assert text =~ ~s|log: "early-tie,late"|
    end

    test "a loop that re-arms itself ends at the step cap", %{conn: conn, t: t} do
      text = send_err!(conn, t, "/", ["Ticker.Msg.Forever", "Ticker.Msg.Race"])
      assert text =~ "step cap reached: 50 effects ran in one step and more were waiting"
      assert text =~ "(Cmd.time.after(10))"
      assert text =~ "a timer that always re-arms itself, never settles"
      # init's 3 ticks, then 50 more.
      assert text =~ "final model: %Ticker.Model{count: 53,"
      refute text =~ "[send] Ticker.Msg.Race"
    end
  end

  describe "Float data" do
    @runs """
    defmodel F.Run do
      id : Uuid
      dps : Float = 0.0
    end

    defmodel F.Sim do
      dps : Float
    end

    defmodel F.Model do
      runs : List<F.Run>
      note : String
    end

    deftype F.Msg do
      Record(String) | Saved(Uuid) | Loaded(List<F.Run>)
    end

    def F.init() : (F.Model, Cmd<F.Msg>) do
      (%F.Model{runs: [], note: ""}, Cmd.store.list(F.Msg.Loaded))
    end

    def F.update(msg : F.Msg, model : F.Model) : (F.Model, Cmd<F.Msg>) do
      case msg do
        F.Msg.Record(json) ->
          case (JSON.parse(json) : Result<F.Sim, String>) do
            Result.Ok(sim) -> (model, Cmd.store.insert(%F.Run{dps: sim.dps * 1.0}, F.Msg.Saved))
            Result.Err(e) -> (%F.Model{model | note: e}, Cmd.none())
          end
        F.Msg.Saved(id) -> (model, Cmd.store.list(F.Msg.Loaded))
        F.Msg.Loaded(rows) -> (%F.Model{model | runs: rows}, Cmd.none())
      end
    end

    def F.view(model : F.Model) : Html<F.Msg> do
      <ul>{List.map(model.runs, fn (r : F.Run) -> <li title={r.dps}>DPS {Float.to_string(r.dps, 1)} raw {r.dps}</li> end)} {model.note}</ul>
    end

    defapp F

    defroutes F.Routes do
      "/" -> F
    end
    """

    test "a JSON number decodes into a Float, is stored as REAL, and renders", %{conn: conn} do
      f = fresh_universe("floats")
      assert {:promoted, _} = Universe.stage(f, "runs", @runs)
      :ok = Deployment.create(f, f, "F.Routes", [])

      text = send!(conn, f, "/", [~S|F.Msg.Record("{\"dps\": 1234.567}")|])
      assert text =~ "Cmd.store.insert(F.Run) -> <uuid"
      assert text =~ "dps: 1234.567"
      assert text =~ "DPS 1234.6 raw 1234.567"

      text = send!(conn, f, "/", [~S|F.Msg.Record("{\"dps\": \"fast\"}")|])
      assert text =~ "expected Float at $.dps"

      {:ok, repo} = Data.open(f)
      {:ok, image} = Universe.image(f)
      models = %{models: image.module.__nobi__(:models), types: image.module.__nobi__(:types)}
      assert {:ok, [{:rec, "F.Run", %{"dps" => 1234.567}}]} = Data.list(repo, "F.Run", models)
    end
  end

  describe "WASM (Cmd.wasm.call)" do
    setup do
      w = fresh_universe("wasm")

      assert {:promoted, _} =
               Universe.stage(w, "w", Nobi.WasmFixture.app(Nobi.WasmFixture.put!()))

      :ok = Deployment.create(w, w, "W.Routes", [])
      %{w: w}
    end

    test "runs the real module; the loop decodes a Float and re-arms on virtual time", %{
      conn: conn,
      w: w
    } do
      text = send!(conn, w, "/", ["W.Msg.Start"])

      assert text =~
               ~r/\[init\]\n  Cmd.wasm.call\(sha256:[0-9a-f]{8}…, echo\) -> Result.Ok\("\{\\"dps\\": 7.25\}"\)/

      assert text =~ ~s|Cmd.wasm.call(|
      assert text =~ ~s|-> Result.Ok("{\\"dps\\": 1234.5}") => W.Msg.Got(Result.Ok(|
      assert text =~ "Cmd.time.after(10) -> fired at 10ms => W.Msg.Start"
      assert text =~ "final model: %W.Model{clicks: 0, dps: 1234.5,"
      assert text =~ "runs: 4}\n\nview text"

      text = send!(conn, w, "/", [~s|W.Msg.Call("spin")|])
      assert text =~ ~s|-> Result.Err("out of fuel")|

      # The next send still works.
      assert send!(conn, w, "/", [~s|W.Msg.Call("upper")|]) =~ ~s|Result.Ok("{\\"DPS\\": 1.5}")|
    end

    test "a spent WASM time budget turns the calls left into Err(timeout)", %{conn: conn, w: w} do
      env = Application.get_env(:nobi, Nobi.Wasm)
      # Fuel that never runs out: the first `spin` takes the whole budget.
      Application.put_env(
        :nobi,
        Nobi.Wasm,
        Keyword.merge(env, send_budget_ms: 300, fuel: 1_000_000_000_000)
      )

      on_exit(fn -> Application.put_env(:nobi, Nobi.Wasm, env) end)

      text = send!(conn, w, "/", ["W.Msg.Burst"])
      [first | rest] = Regex.scan(~r/Cmd.wasm.call\(sha256:[0-9a-f]{8}…, spin\) -> .*/, text)
      assert hd(first) =~ ~s|-> Result.Err("timeout") => W.Msg.Got(Result.Err("timeout"))|
      refute hd(first) =~ "budget"
      assert length(rest) == 4

      for [line] <- rest,
          do: assert(line =~ ~s|Result.Err("timeout")| and line =~ "WASM time budget is spent")
    end
  end

  describe "bounds" do
    test "at most 20 messages, and nothing runs past that", %{conn: conn, d: d, u: u} do
      text = send_err!(conn, d, "/", List.duplicate("B.Msg.Post", 21))
      assert text =~ "send takes at most 20 messages, got 21; nothing ran"
      assert rows(d, u) == []
    end

    test "effects without a callback count toward the cap; listings are cut", %{
      conn: conn,
      d: d
    } do
      text = send_err!(conn, d, "/", ["B.Msg.Burst", "B.Msg.Post"])
      # 60 blob.puts, none with a callback that runs: the cap stops at 50.
      assert text =~ "step cap reached: 50 effects"
      assert text =~ ~r/waiting \((Cmd.blob.put, ){4}Cmd.blob.put, … 5 more\)/
      # 20 effect lines shown, then the count of the rest.
      assert text =~ "… 30 more effects (50 failed in all)"
      assert length(Regex.scan(~r/^  Cmd.blob.put -> ERROR/m, text)) == 20
      refute text =~ "[send] B.Msg.Post"
    end

    test "the reply stays under 20000 characters, keeping the final model and view", %{
      conn: conn,
      d: d
    } do
      big = String.duplicate("x", 5_000)
      text = send!(conn, d, "/", List.duplicate(~s|B.Msg.Draft("#{big}")|, 20))
      assert String.length(text) < 20_500
      assert text =~ "steps cut at 20000 characters in all"
      assert text =~ "final model: %B.Model{"
      assert text =~ "view text: Board"
    end
  end
end
