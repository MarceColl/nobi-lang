defmodule NobiWeb.McpTest do
  use NobiWeb.ConnCase, async: false

  import Nobi.UniverseHelpers

  @counter File.read!("test/fixtures/nobi/counter.nobi")
  @split File.read!("test/fixtures/nobi/split.nobi")
  @g "def A.g() : Int do\n  1\nend"
  @f "def A.f() : Int do\n  A.g()\nend"

  @tool_names ~w(list_universes create_universe stage_patch unstage list_staged read symbols eval test history health list_deployments create_deployment guide send)

  # ---------- helpers ----------

  defp post_raw(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post("/mcp", body)
  end

  defp rpc_body(method), do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method})

  defp rpc(conn, method, params \\ nil, id \\ 1) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    msg = if params, do: Map.put(msg, "params", params), else: msg
    conn = post_raw(conn, Jason.encode!(msg))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  # A tools/call that must come back as a result: `{text, isError}`.
  defp call(conn, name, args) do
    {200, %{"jsonrpc" => "2.0", "id" => 1, "result" => result}} =
      rpc(conn, "tools/call", %{"name" => name, "arguments" => args})

    %{"content" => [%{"type" => "text", "text" => text}], "isError" => error?} = result
    {text, error?}
  end

  defp ok!(conn, name, args) do
    {text, false} = call(conn, name, args)
    text
  end

  defp err!(conn, name, args) do
    {text, true} = call(conn, name, args)
    text
  end

  setup %{conn: conn} do
    %{conn: conn, u: fresh_universe("mcp")}
  end

  # ---------- protocol ----------

  describe "handshake" do
    test "initialize echoes a supported protocol version and gives instructions", %{conn: conn} do
      {200, %{"id" => 1, "result" => result}} =
        rpc(conn, "initialize", %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0"}
        })

      assert result["protocolVersion"] == "2025-03-26"
      assert result["serverInfo"]["name"] == "nobi"
      assert is_binary(result["serverInfo"]["version"])
      assert result["capabilities"] == %{"tools" => %{}}
      assert result["instructions"] =~ "stage_patch"
    end

    test "an unknown protocol version gets ours", %{conn: conn} do
      {200, %{"result" => %{"protocolVersion" => "2025-06-18"}}} =
        rpc(conn, "initialize", %{"protocolVersion" => "1999-01-01"})
    end

    test "notifications are accepted with 202 and no body", %{conn: conn} do
      conn =
        post_raw(conn, ~s({"jsonrpc":"2.0","method":"notifications/initialized"}))

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "ping answers an empty result", %{conn: conn} do
      assert {200, %{"id" => 7, "result" => %{}}} = rpc(conn, "ping", nil, 7)
    end

    test "string ids are echoed", %{conn: conn} do
      assert {200, %{"id" => "abc", "result" => %{}}} = rpc(conn, "ping", nil, "abc")
    end

    test "GET is not allowed", %{conn: conn} do
      conn = get(conn, "/mcp")
      assert conn.status == 405
    end
  end

  describe "instructions" do
    test "list every stdlib def, generated from the stdlib table", %{conn: conn} do
      {200, %{"result" => %{"instructions" => text}}} = rpc(conn, "initialize", %{})

      for name <- Nobi.Lang.Types.Stdlib.names(),
          match?({:def, _, _, _}, Nobi.Lang.Types.Stdlib.signature(name)) do
        assert text =~ name <> "(", "missing #{name}"
      end

      assert text =~ "Map.get("
      assert text =~ "list_universes"
      refute text =~ "fork_env"
      refute text =~ "workspace"
    end

    test "the DECLARATIONS example is shown, promotes as written, and runs", %{
      conn: conn,
      u: u
    } do
      example = NobiWeb.Mcp.Instructions.example()
      {200, %{"result" => %{"instructions" => text}}} = rpc(conn, "initialize", %{})

      assert text =~ "DECLARATIONS"

      for line <- String.split(example, "\n", trim: true),
          do: assert(text =~ "  " <> line, "the instructions lack: #{line}")

      for form <-
            ["defmodel ", "deftype ", "shown = ", " if ", "on-click={", "defapp "] ++
              ["id : Uuid", "saves : Int = 1", "Cmd.store.insert(", "Cmd.store.tx(", "Store.get("],
          do: assert(example =~ form, "the example lacks #{form}")

      assert ok!(conn, "stage_patch", %{"universe" => u, "id" => "ex", "source" => example}) ==
               "promoted: ex"

      assert ok!(conn, "eval", %{
               "universe" => u,
               "expression" =>
                 "Counter.update(Counter.Msg.Add(5), %Counter.Model{count: 1, label: \"x\", snapshots: []})"
             }) =~ "count: 6"
    end
  end

  describe "robustness (Review Focus 5)" do
    test "malformed JSON is -32700, not a 500", %{conn: conn} do
      conn = post_raw(conn, ~s({"jsonrpc": "2.0", "id": 1, "method": ))
      assert conn.status == 400

      assert %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32700}} =
               Jason.decode!(conn.resp_body)
    end

    test "a batch is refused with a JSON-RPC error", %{conn: conn} do
      conn =
        post_raw(conn, ~s([{"jsonrpc":"2.0","id":1,"method":"ping"}]))

      assert conn.status == 400
      assert %{"error" => %{"code" => -32600}, "id" => nil} = Jason.decode!(conn.resp_body)
    end

    test "a non-object body is an invalid request", %{conn: conn} do
      conn = post_raw(conn, "42")
      assert %{"error" => %{"code" => -32600}} = Jason.decode!(conn.resp_body)
    end

    test "a request without jsonrpc 2.0 is an invalid request", %{conn: conn} do
      conn = post_raw(conn, ~s({"id":3,"method":"ping"}))
      assert %{"error" => %{"code" => -32600}, "id" => 3} = Jason.decode!(conn.resp_body)
    end

    test "an unknown method is -32601", %{conn: conn} do
      assert {200, %{"id" => 1, "error" => %{"code" => -32601}}} = rpc(conn, "nope/nope")
    end

    test "an unknown tool is -32602", %{conn: conn} do
      assert {200, %{"error" => %{"code" => -32602, "message" => message}}} =
               rpc(conn, "tools/call", %{"name" => "frobnicate", "arguments" => %{}})

      assert message =~ "frobnicate"
    end

    test "tools/call without a name, or with non-object arguments, is -32602", %{conn: conn} do
      assert {200, %{"error" => %{"code" => -32602}}} = rpc(conn, "tools/call", %{})

      assert {200, %{"error" => %{"code" => -32602}}} =
               rpc(conn, "tools/call", %{"name" => "symbols", "arguments" => [1]})

      assert {200, %{"error" => %{"code" => -32602}}} = rpc(conn, "tools/call", [1])
    end

    test "a missing or ill-typed argument is an isError result naming it", %{conn: conn, u: u} do
      assert err!(conn, "read", %{"universe" => u}) =~ "symbol"
      assert err!(conn, "eval", %{"universe" => u, "expression" => 1}) =~ "expression"
      assert err!(conn, "stage_patch", %{"universe" => u, "id" => "p"}) =~ "source"

      assert err!(conn, "stage_patch", %{
               "universe" => u,
               "id" => "p",
               "source" => @g,
               "remove" => "A.x"
             }) =~ "remove"

      assert err!(conn, "symbols", %{"universe" => 5}) =~ "universe"
    end

    @tag :capture_log
    test "a tool that raises is an isError result, never a 500", %{conn: conn} do
      conn = put_private(conn, :mcp_tools, NobiWeb.McpRaisingTools)

      {text, true} = call(conn, "boom", %{})
      assert text =~ "kaboom"
    end

    @tag :capture_log
    test "a tool that exits is an isError result too", %{conn: conn} do
      conn = put_private(conn, :mcp_tools, NobiWeb.McpRaisingTools)

      {text, true} = call(conn, "exit", %{})
      assert text =~ "internal"
    end
  end

  describe "request guard" do
    defp stage_body(u, id),
      do:
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "stage_patch",
            "arguments" => %{"universe" => u, "id" => id, "source" => @g}
          }
        })

    test "a foreign Origin is 403 and nothing runs", %{conn: conn, u: u} do
      conn =
        conn |> put_req_header("origin", "https://evil.example") |> post_raw(stage_body(u, "g"))

      assert conn.status == 403
      assert %{"error" => %{"code" => -32600}, "id" => nil} = Jason.decode!(conn.resp_body)
      assert Nobi.Universe.symbols(u) == []
      assert Nobi.Universe.staged(u) == []
    end

    test "a cross-site simple request (text/plain) is 415 and nothing runs", %{conn: conn, u: u} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.example")
        |> put_req_header("content-type", "text/plain")
        |> post("/mcp", stage_body(u, "g"))

      assert conn.status in [403, 415]

      conn =
        build_conn()
        |> put_req_header("content-type", "text/plain")
        |> post("/mcp", stage_body(u, "g"))

      assert conn.status == 415
      assert %{"error" => %{"code" => -32600}} = Jason.decode!(conn.resp_body)
      assert Nobi.Universe.symbols(u) == []
    end

    test "local origins, and no Origin at all, are served", %{conn: conn, u: u} do
      for origin <- ["http://localhost:4000", "http://127.0.0.1:4123", "http://[::1]:4000"] do
        c = build_conn() |> put_req_header("origin", origin) |> post_raw(rpc_body("ping"))
        assert c.status == 200, origin
      end

      c = conn |> post_raw(stage_body(u, "g"))
      assert c.status == 200
      assert [%{symbol: "A.g"}] = Nobi.Universe.symbols(u)
    end

    test "content type with a charset is accepted", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json; charset=utf-8")
        |> post("/mcp", rpc_body("ping"))

      assert conn.status == 200
    end

    test "MCP-Protocol-Version: a supported one passes, an unknown one is 400", %{conn: conn} do
      ok =
        conn |> put_req_header("mcp-protocol-version", "2025-06-18") |> post_raw(rpc_body("ping"))

      assert ok.status == 200

      bad =
        build_conn()
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> post_raw(rpc_body("ping"))

      assert bad.status == 400
      assert %{"error" => %{"code" => -32600, "message" => m}} = Jason.decode!(bad.resp_body)
      assert m =~ "1999-01-01"
    end
  end

  describe "instructions: facts from a real agent run" do
    defp instructions(conn) do
      {200, %{"result" => %{"instructions" => text}}} = rpc(conn, "initialize", %{})
      text
    end

    test "every tool the instructions name exists, and the deployment tools are named", %{
      conn: conn
    } do
      text = instructions(conn)
      tools = Enum.map(NobiWeb.Mcp.Tools.list(), & &1.name)

      for tool <- tools, do: assert(text =~ "`#{tool}`", "unmentioned: `#{tool}`")

      named =
        Regex.scan(~r/`([a-z]+_[a-z_]+)`/, text, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      for name <- named,
          String.contains?(name, ["deploy", "stage", "universe"]),
          do: assert(name in tools, "the instructions name a tool that does not exist: #{name}")

      assert text =~ "create_deployment"
      assert text =~ "list_deployments"
      assert text =~ "http://localhost:#{NobiWeb.Endpoint.config(:http)[:port]}/"
    end

    # Claude Code shows a server's instructions only up to about 4096
    # characters: what prevents the run's errors must come before that.
    test "the facts that prevent the run's errors fit in the first 4000 characters", %{
      conn: conn
    } do
      head = NobiWeb.Mcp.Instructions.head()
      assert String.length(head) <= 4000, "head is #{String.length(head)} characters"
      assert String.starts_with?(instructions(conn), head)

      for fact <-
            [
              "`guide`",
              "NO list patterns",
              "there is no `t.0`",
              "no List.find",
              "List.head(List.filter(",
              "bare declaration",
              "Any other on-* (on-input too) is refused",
              "on-change={",
              "no `(a, b) = e`",
              "create_deployment",
              "Counter.Routes",
              "SERVING YOUR APP",
              "ONE expression",
              "never a type\nvariable",
              "no `!`, `&&` or `||`",
              "Construction lists EVERY field"
            ],
          do: assert(head =~ fact, "the head lacks #{fact}")
    end

    test "guide answers the whole instructions", %{conn: conn} do
      text = ok!(conn, "guide", %{})
      assert text == instructions(conn)
      assert text =~ "THE WHOLE STDLIB"
      assert text =~ "DECLARATIONS"
    end

    test "every code example promotes, in order, in a fresh universe", %{conn: conn, u: u} do
      text = instructions(conn)

      for {source, i} <- Enum.with_index(NobiWeb.Mcp.Instructions.examples()) do
        for line <- String.split(source, "\n", trim: true),
            do: assert(text =~ String.trim(line), "the instructions lack: #{line}")

        assert ok!(conn, "stage_patch", %{"universe" => u, "id" => "ex#{i}", "source" => source}) ==
                 "promoted: ex#{i}"
      end
    end

    test "the documented idioms work: List.head of List.filter, a tuple taken apart by case",
         %{conn: conn, u: u} do
      text = instructions(conn)
      assert text =~ "no List.find"
      assert text =~ "List.head(List.filter("

      assert ok!(conn, "eval", %{
               "universe" => u,
               "expression" => "List.head(List.filter([1, 2, 3], fn (x : Int) -> x > 1 end))"
             }) == "Option.Some(2) : Option<Int>"

      assert ok!(conn, "eval", %{
               "universe" => u,
               "expression" => "case (1, \"a\") do\n  (n, s) -> n\nend"
             }) == "1 : Int"
    end

    # Each "there is no X" the instructions state is still true: if the
    # language gains one, this fails and the instructions must change.
    test "what the instructions say does not exist, does not", %{conn: conn, u: u} do
      text = instructions(conn)
      [example | _] = NobiWeb.Mcp.Instructions.examples()

      "promoted: ex" =
        ok!(conn, "stage_patch", %{"universe" => u, "id" => "ex", "source" => example})

      stage = fn source ->
        ok!(conn, "stage_patch", %{"universe" => u, "id" => "p", "source" => source})
      end

      # List patterns.
      assert text =~ "NO list patterns"

      assert stage.(
               "def A.first(xs : List<Int>) : Int do\n  case xs do\n    [x | _] -> x\n    [] -> 0\n  end\nend"
             ) =~
               "expected a pattern, got '['"

      # Tuple element access.
      assert text =~ "there is no `t.0`"

      assert err!(conn, "eval", %{"universe" => u, "expression" => "Counter.init().0"}) =~
               "[parse]"

      # defapp takes no block.
      assert text =~ "bare declaration"
      assert stage.("defapp Counter do\n  init: Counter.init\nend") =~ "[parse]"
      assert stage.("defapp counter") =~ "must end in a capitalized segment"

      # on-input, like any event the renderer does not wire, is refused; on-change takes the constructor.
      assert text =~ "Any other on-* (on-input too) is refused"

      view = fn attr ->
        "def Counter.box(model : Counter.Model) : Html<Counter.Msg> do\n  <input value={model.label} #{attr}={Counter.Msg.Rename} />\nend"
      end

      assert stage.(view.("on-input")) =~ "[bad-event] on-input is not an event Nobi wires"

      assert stage.(view.("on-dblclick")) =~
               "[bad-event] on-dblclick is not an event Nobi wires"

      assert stage.(view.("on-change")) == "promoted: p"

      # A binding names one value.
      assert stage.("def A.g() : Int do\n  (a, b) = (1, 2)\n  a\nend") =~
               "a binding names one value"

      # A binding in a case arm.
      assert stage.(
               "def A.f(n : Int) : Int do\n  case n do\n    1 ->\n      m = n + 1\n      m\n    _ -> 0\n  end\nend"
             ) =~
               "expected a pattern, got '='"

      # A type variable in an annotation.
      assert stage.("def A.header() : Html<a> do\n  <h1>Hi</h1>\nend") =~ "unknown type `a`"

      # JSX text keeps its in-line spaces (React's rule).
      assert ok!(conn, "eval", %{"universe" => u, "expression" => "<span>by {\"x\"}</span>"}) =~
               ~s|<span>by {"x"}</span>|

      # Boolean operators are words.
      assert err!(conn, "eval", %{"universe" => u, "expression" => "!true"}) =~ "[parse]"
      assert err!(conn, "eval", %{"universe" => u, "expression" => "true && true"}) =~ "[parse]"

      assert ok!(conn, "eval", %{"universe" => u, "expression" => "not true or false and true"}) ==
               "false : Bool"

      # List.find.
      assert err!(conn, "eval", %{
               "universe" => u,
               "expression" => "List.find([1], fn (x : Int) -> true end)"
             }) =~
               "no `List.find`"
    end
  end

  # ---------- tools ----------

  describe "tools/list" do
    test "names every tool, each with an object inputSchema", %{conn: conn} do
      {200, %{"result" => %{"tools" => tools}}} = rpc(conn, "tools/list")

      assert Enum.sort(Enum.map(tools, & &1["name"])) == Enum.sort(@tool_names)

      for tool <- tools do
        assert is_binary(tool["description"]) and tool["description"] != ""
        assert %{"type" => "object", "properties" => props} = tool["inputSchema"]
        assert is_map(props)

        for req <- Map.get(tool["inputSchema"], "required", []),
            do: assert(Map.has_key?(props, req))
      end

      by_name = Map.new(tools, &{&1["name"], &1})
      assert by_name["stage_patch"]["inputSchema"]["required"] == ["id", "source"]
      assert by_name["eval"]["inputSchema"]["properties"]["universe"]["type"] == "string"
    end
  end

  describe "universes" do
    test "list_universes and create_universe", %{conn: conn, u: u} do
      assert ok!(conn, "list_universes", %{}) =~ u
      name = "mcp-new-#{System.unique_integer([:positive])}"
      stop_on_exit(name)

      assert ok!(conn, "create_universe", %{"name" => name}) =~ "created: #{name}"
      assert ok!(conn, "list_universes", %{}) |> String.split("\n") |> Enum.member?(name)
      assert err!(conn, "create_universe", %{"name" => name}) =~ "already exists"
      assert err!(conn, "create_universe", %{"name" => "Bad Name"}) =~ "bad universe name"
      assert err!(conn, "create_universe", %{}) =~ "name"
    end

    test "an unknown universe is an isError result on every universe tool", %{conn: conn} do
      nope = "nope-#{System.unique_integer([:positive])}"

      for {tool, args} <- [
            {"stage_patch", %{"id" => "p", "source" => @g}},
            {"unstage", %{"id" => "p"}},
            {"list_staged", %{}},
            {"read", %{"symbol" => "A.g"}},
            {"symbols", %{}},
            {"eval", %{"expression" => "1"}},
            {"test", %{"symbol" => "A.t"}},
            {"history", %{}},
            {"health", %{}},
            {"create_deployment", %{"name" => "d", "routes" => "Main"}}
          ] do
        assert err!(conn, tool, Map.put(args, "universe", nope)) =~ "no such universe: #{nope}"
        assert err!(conn, tool, Map.put(args, "universe", "Not A Name")) =~ "bad universe name"
      end
    end

    test "list_universes with none says so", %{conn: conn} do
      Nobi.Repo.query!("delete from universes")
      assert ok!(conn, "list_universes", %{}) == "no universes"
    end

    test "the universe argument defaults to main", %{conn: conn} do
      stop_on_exit("main")
      {_text, false} = call(conn, "symbols", %{})
      {_text, false} = call(conn, "eval", %{"expression" => "1 + 1"})
    end
  end

  describe "stage_patch, list_staged, unstage" do
    test "promoted reads `promoted: ids`", %{conn: conn, u: u} do
      assert ok!(conn, "stage_patch", %{"universe" => u, "id" => "g", "source" => @g}) ==
               "promoted: g"
    end

    test "a staged patch reads `staged:` with its reasons", %{conn: conn, u: u} do
      text = ok!(conn, "stage_patch", %{"universe" => u, "id" => "f", "source" => @f})
      assert text =~ ~r/\Astaged: f/
      assert text =~ "- A.f [unbound]"

      listed = ok!(conn, "list_staged", %{"universe" => u})
      assert listed =~ "f"
      assert listed =~ "- A.f [unbound]"
      assert listed =~ "A.g()"

      assert ok!(conn, "unstage", %{"universe" => u, "id" => "f"}) =~ "unstaged: f"
      assert err!(conn, "unstage", %{"universe" => u, "id" => "f"}) =~ "nothing staged under f"
      assert ok!(conn, "list_staged", %{"universe" => u}) =~ "no staged patches"
    end

    test "a staged verdict says each reason once", %{conn: conn, u: u} do
      # Both branches update a field the model lacks: two identical reasons.
      src = """
      defmodel Tally.Model do
        n : Int
      end
      def Tally.update(b : Bool, model : Tally.Model) : Tally.Model do
        if b do %Tally.Model{model | counts: 1} else %Tally.Model{model | counts: 2} end
      end
      """

      line = "- Tally.update [extra-field] model `Tally.Model` has no field `counts`"

      for text <- [
            ok!(conn, "stage_patch", %{"universe" => u, "id" => "tally", "source" => src}),
            ok!(conn, "list_staged", %{"universe" => u})
          ] do
        assert text =~ line
        assert length(String.split(text, line)) == 2, text
      end
    end

    test "a parse error is staged with a parse reason", %{conn: conn, u: u} do
      text = ok!(conn, "stage_patch", %{"universe" => u, "id" => "p", "source" => "def ("})
      assert text =~ "staged: p"
      assert text =~ "[parse]"
    end

    test "remove takes symbols out", %{conn: conn, u: u} do
      "promoted: g" = ok!(conn, "stage_patch", %{"universe" => u, "id" => "g", "source" => @g})

      assert ok!(conn, "stage_patch", %{
               "universe" => u,
               "id" => "rm",
               "source" => "",
               "remove" => ["A.g"]
             }) == "promoted: rm"

      assert err!(conn, "read", %{"universe" => u, "symbol" => "A.g"}) =~ "no symbol named A.g"
      assert ok!(conn, "history", %{"universe" => u}) =~ "removed: A.g"
    end
  end

  describe "read, symbols, history" do
    test "on an empty and a populated universe", %{conn: conn, u: u} do
      assert ok!(conn, "symbols", %{"universe" => u}) =~ "no symbols"
      assert ok!(conn, "history", %{"universe" => u}) =~ "no commits"
      assert err!(conn, "read", %{"universe" => u, "symbol" => "A.g"}) =~ "no symbol named A.g"

      "promoted: g" = ok!(conn, "stage_patch", %{"universe" => u, "id" => "g", "source" => @g})

      assert ok!(conn, "read", %{"universe" => u, "symbol" => "A.g"}) =~ "def A.g() : Int do"
      assert ok!(conn, "symbols", %{"universe" => u}) =~ "A.g() : Int"
      assert ok!(conn, "history", %{"universe" => u}) =~ "1. g: A.g"
    end
  end

  describe "eval and test" do
    test "eval reads `value : type`; errors are isError", %{conn: conn, u: u} do
      assert ok!(conn, "eval", %{"universe" => u, "expression" => "1 + 2"}) == "3 : Int"

      assert err!(conn, "eval", %{"universe" => u, "expression" => "A.missing()"}) =~
               "[unbound]"

      assert err!(conn, "eval", %{"universe" => u, "expression" => "1 +"}) =~ "[parse]"
    end

    test "an error lists each reason once, and none that repeats the error line", %{
      conn: conn,
      u: u
    } do
      text = err!(conn, "eval", %{"universe" => u, "expression" => "A.zz() + A.zz()"})
      assert [_head] = String.split(text, "\n")

      text = err!(conn, "eval", %{"universe" => u, "expression" => "A.zz() + A.yy()"})
      assert [head, reason] = String.split(text, "\n")
      assert head =~ "A.zz"
      assert reason =~ "A.yy"
    end

    test "eval of a symbol only a staged patch defines says it is staged", %{conn: conn, u: u} do
      ok!(conn, "stage_patch", %{"universe" => u, "id" => "wip", "source" => @f})

      assert err!(conn, "eval", %{"universe" => u, "expression" => "A.f()"}) =~
               "(staged under `wip`, not promoted)"
    end

    test "test runs a deftest; failures and unknown tests are isError", %{conn: conn, u: u} do
      assert ok!(conn, "stage_patch", %{"universe" => u, "id" => "split", "source" => @split}) ==
               "promoted: split"

      assert ok!(conn, "test", %{"universe" => u, "symbol" => "Split.money_prints_cents"}) =~
               "Split.money_prints_cents: ok"

      failing = "deftest Split.lies do\n  always(Split.money(5) == \"5.00\")\nend"

      "promoted: lies" =
        ok!(conn, "stage_patch", %{"universe" => u, "id" => "lies", "source" => failing})

      assert err!(conn, "test", %{"universe" => u, "symbol" => "Split.lies"}) =~
               "Split.lies: FAILED"

      assert err!(conn, "test", %{"universe" => u, "symbol" => "Split.nope"}) =~ "Split.nope"
    end
  end

  describe "health" do
    test "a healthy universe", %{conn: conn, u: u} do
      assert ok!(conn, "health", %{"universe" => u}) =~ "ok: #{u} is healthy"
    end

    test "a degraded universe says so in health, list_universes and symbols; a fix heals it",
         %{conn: conn, u: u} do
      store_commit(u, @f)

      ExUnit.CaptureLog.capture_log(fn ->
        text = ok!(conn, "health", %{"universe" => u})
        assert text =~ "degraded: #{u}"
        assert text =~ "- A.f [unbound]"
      end)

      assert ok!(conn, "list_universes", %{}) =~ "#{u} (DEGRADED: A.f"
      assert ok!(conn, "symbols", %{"universe" => u}) =~ ~r/\ADEGRADED: A.f .*\nA.f\(\) : Int/
      assert err!(conn, "eval", %{"universe" => u, "expression" => "1"}) =~ "[degraded]"

      assert ok!(conn, "stage_patch", %{"universe" => u, "id" => "fix", "source" => @g}) ==
               "promoted: fix"

      assert ok!(conn, "health", %{"universe" => u}) =~ "is healthy"
      refute ok!(conn, "list_universes", %{}) =~ "DEGRADED"
      assert ok!(conn, "eval", %{"universe" => u, "expression" => "A.f()"}) == "1 : Int"
    end
  end

  describe "deployments" do
    @describetag :tmp_dir
    setup %{tmp_dir: dir}, do: isolated_data(dir)

    # `u` with the instructions' example promoted (route table `Main`).
    defp with_example(conn, u) do
      example = NobiWeb.Mcp.Instructions.example()

      "promoted: ex" =
        ok!(conn, "stage_patch", %{"universe" => u, "id" => "ex", "source" => example})

      u
    end

    defp port, do: NobiWeb.Endpoint.config(:http)[:port]

    test "create_deployment serves the route table at <name>.localhost", %{conn: conn, u: u} do
      with_example(conn, u)

      text =
        ok!(conn, "create_deployment", %{"name" => u, "routes" => "Main", "universe" => u})

      assert text =~ "http://#{u}.localhost:#{port()}/"

      assert {:ok, %{name: ^u, universe: ^u, routes: "Main", commit: nil}} =
               Nobi.Deployment.resolve("#{u}.localhost")

      html = %{build_conn() | host: "#{u}.localhost"} |> get("/") |> html_response(200)
      assert html =~ "clicks: 0"
    end

    test "create_deployment takes extra hosts and defaults to main", %{conn: conn} do
      stop_on_exit("main")
      with_example(conn, "main")
      name = "d-#{System.unique_integer([:positive])}"

      text =
        ok!(conn, "create_deployment", %{
          "name" => name,
          "routes" => "Main",
          "hosts" => ["forum.example.test"]
        })

      assert text =~ "http://#{name}.localhost:#{port()}/"
      assert text =~ "http://forum.example.test:#{port()}/"

      assert {:ok, %{name: ^name, universe: "main"}} =
               Nobi.Deployment.resolve("forum.example.test")
    end

    test "create_deployment errors are plain and actionable", %{conn: conn, u: u} do
      with_example(conn, u)
      args = %{"name" => u, "routes" => "Main", "universe" => u}
      ok!(conn, "create_deployment", args)

      assert err!(conn, "create_deployment", args) =~ "deployment #{u} already exists"

      assert err!(conn, "create_deployment", %{args | "name" => "Bad Name"}) =~
               "bad deployment name: \"Bad Name\""

      assert err!(conn, "create_deployment", %{args | "name" => "x2", "universe" => "nope-zz"}) =~
               "no such universe: nope-zz"

      text = err!(conn, "create_deployment", %{args | "name" => "x3", "routes" => "Forum.Routes"})
      assert text =~ "no route table Forum.Routes"
      assert text =~ "defroutes Forum.Routes"
      assert text =~ "Main"

      assert err!(conn, "create_deployment", %{"name" => "x4"}) =~
               "missing required argument `routes`"

      assert err!(conn, "create_deployment", Map.put(args, "hosts", "a.test")) =~
               "argument `hosts` must be an array of strings"

      assert Nobi.Deployment.get("x3") == :error
    end

    test "create_deployment refuses another deployment's hosts, each with its reason", %{
      conn: conn,
      u: u
    } do
      with_example(conn, u)
      args = %{"name" => u, "routes" => "Main", "universe" => u}
      ok!(conn, "create_deployment", Map.put(args, "hosts", ["shop.example.test"]))
      other = %{args | "name" => "#{u}-b"}

      assert err!(conn, "create_deployment", Map.put(other, "hosts", ["localhost"])) =~
               "belong to the built-in `local` deployment"

      assert err!(conn, "create_deployment", Map.put(other, "hosts", ["#{u}.localhost"])) =~
               "belongs to another deployment"

      assert err!(conn, "create_deployment", Map.put(other, "hosts", ["Shop.example.test"])) =~
               "already another deployment's"

      assert err!(conn, "create_deployment", Map.put(other, "hosts", ["a b.test"])) =~
               "not a DNS name"

      assert Nobi.Deployment.get("#{u}-b") == :error
    end

    test "local still serves / after an attempted hijack of localhost", %{conn: conn} do
      stop_on_exit("main")
      with_example(conn, "main")
      :ok = Nobi.Deployment.ensure_local()

      err!(conn, "create_deployment", %{
        "name" => "a",
        "routes" => "Main",
        "hosts" => ["localhost"]
      })

      err!(conn, "create_deployment", %{
        "name" => "b",
        "routes" => "Main",
        "hosts" => ["local.localhost", "127.0.0.1"]
      })

      html = %{build_conn() | host: "localhost"} |> get("/") |> html_response(200)
      assert html =~ "clicks: 0"
      assert {:ok, %{name: "local"}} = Nobi.Deployment.resolve("localhost")
    end

    test "in local mode a host that is not a localhost name is refused", %{conn: conn, u: u} do
      with_example(conn, u)
      previous = Application.fetch_env(:nobi, :mode)
      Application.put_env(:nobi, :mode, :local)

      on_exit(fn ->
        case previous do
          {:ok, mode} -> Application.put_env(:nobi, :mode, mode)
          :error -> Application.delete_env(:nobi, :mode)
        end
      end)

      conn = %{conn | host: "localhost"}
      args = %{"name" => u, "routes" => "Main", "universe" => u}

      assert err!(conn, "create_deployment", Map.put(args, "hosts", ["forum.example.com"])) =~
               "local mode serves only localhost names"

      assert ok!(conn, "create_deployment", Map.put(args, "hosts", ["#{u}.localhost"])) =~
               "http://#{u}.localhost:#{port()}/"
    end

    test "URLs list <name>.localhost only where it is served", %{conn: conn, u: u} do
      with_example(conn, u)
      previous = Application.fetch_env(:nobi, :localhost_deployments)
      Application.put_env(:nobi, :localhost_deployments, false)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:nobi, :localhost_deployments, v)
          :error -> Application.delete_env(:nobi, :localhost_deployments)
        end
      end)

      args = %{"name" => u, "routes" => "Main", "universe" => u}
      assert ok!(conn, "create_deployment", args) =~ "no URL"
      refute ok!(conn, "list_deployments", %{}) =~ "#{u}.localhost"

      ok!(
        conn,
        "create_deployment",
        %{args | "name" => "#{u}-h"} |> Map.put("hosts", ["h.example.test"])
      )

      line =
        ok!(conn, "list_deployments", %{})
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "#{u}-h:"))

      assert line =~ "http://h.example.test:#{port()}/"
      refute line =~ ".localhost"
    end

    test "list_deployments shows each deployment's routes, head and URLs", %{conn: conn, u: u} do
      with_example(conn, u)

      ok!(conn, "create_deployment", %{
        "name" => u,
        "routes" => "Main",
        "universe" => u,
        "hosts" => ["c.example.test"]
      })

      text = ok!(conn, "list_deployments", %{})
      [line] = text |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, u <> ":"))
      assert line =~ "universe #{u}"
      assert line =~ "routes Main"
      assert line =~ "follows head"
      assert line =~ "http://#{u}.localhost:#{port()}/"
      assert line =~ "http://c.example.test:#{port()}/"

      :ok = Nobi.Deployment.pin(u, 1)
      assert ok!(conn, "list_deployments", %{}) =~ ~r/^#{u}: .*pinned to commit 1/m
    end
  end

  # ---------- end to end ----------

  test "an agent drives the counter corpus through /mcp", %{conn: conn} do
    u = "e2e-#{System.unique_integer([:positive])}"
    stop_on_exit(u)

    {200, %{"result" => %{"instructions" => _}}} =
      rpc(conn, "initialize", %{"protocolVersion" => "2025-06-18"})

    assert ok!(conn, "create_universe", %{"name" => u}) =~ "created"

    assert ok!(conn, "stage_patch", %{"universe" => u, "id" => "counter", "source" => @counter}) ==
             "promoted: counter"

    assert ok!(conn, "eval", %{
             "universe" => u,
             "expression" => "Counter.update(Counter.Msg.Add(5), %Counter.Model{count: 1})"
           }) ==
             "(%Counter.Model{count: 6}, Cmd.none()) : (Counter.Model, Cmd<Counter.Msg>)"

    broken = "def Counter.double(m : Counter.Model) : Int do\n  Counter.twice(m.count)\nend"

    assert ok!(conn, "stage_patch", %{"universe" => u, "id" => "double", "source" => broken}) =~
             "staged: double"

    assert ok!(conn, "list_staged", %{"universe" => u}) =~ "- Counter.double [unbound]"

    fixed = "def Counter.twice(n : Int) : Int do\n  n * 2\nend\n" <> broken

    assert ok!(conn, "stage_patch", %{"universe" => u, "id" => "double", "source" => fixed}) ==
             "promoted: double"

    assert ok!(conn, "list_staged", %{"universe" => u}) =~ "no staged patches"

    assert ok!(conn, "eval", %{
             "universe" => u,
             "expression" => "Counter.double(%Counter.Model{count: 21})"
           }) == "42 : Int"

    history = ok!(conn, "history", %{"universe" => u})
    assert history =~ "1. counter:"
    assert history =~ "2. double: Counter.double, Counter.twice"
  end
end
