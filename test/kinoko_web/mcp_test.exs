defmodule KinokoWeb.McpTest do
  use KinokoWeb.ConnCase, async: false

  import Kinoko.UniverseHelpers

  @counter File.read!("test/fixtures/yabu/counter.yabu")
  @split File.read!("test/fixtures/yabu/split.yabu")
  @g "def A.g() : Int do\n  1\nend"
  @f "def A.f() : Int do\n  A.g()\nend"

  @tool_names ~w(list_universes create_universe stage_patch unstage list_staged read symbols eval test history)

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
      assert result["serverInfo"]["name"] == "kinoko"
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

      for name <- Kinoko.Lang.Types.Stdlib.names(),
          match?({:def, _, _}, Kinoko.Lang.Types.Stdlib.signature(name)) do
        assert text =~ name <> "(", "missing #{name}"
      end

      assert text =~ "list_universes"
      refute text =~ "fork_env"
      refute text =~ "workspace"
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
      conn = put_private(conn, :mcp_tools, KinokoWeb.McpRaisingTools)

      {text, true} = call(conn, "boom", %{})
      assert text =~ "kaboom"
    end

    @tag :capture_log
    test "a tool that exits is an isError result too", %{conn: conn} do
      conn = put_private(conn, :mcp_tools, KinokoWeb.McpRaisingTools)

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
      assert Kinoko.Universe.symbols(u) == []
      assert Kinoko.Universe.staged(u) == []
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
      assert Kinoko.Universe.symbols(u) == []
    end

    test "local origins, and no Origin at all, are served", %{conn: conn, u: u} do
      for origin <- ["http://localhost:4000", "http://127.0.0.1:4123", "http://[::1]:4000"] do
        c = build_conn() |> put_req_header("origin", origin) |> post_raw(rpc_body("ping"))
        assert c.status == 200, origin
      end

      c = conn |> post_raw(stage_body(u, "g"))
      assert c.status == 200
      assert [%{symbol: "A.g"}] = Kinoko.Universe.symbols(u)
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
            {"history", %{}}
          ] do
        assert err!(conn, tool, Map.put(args, "universe", nope)) =~ "no such universe: #{nope}"
        assert err!(conn, tool, Map.put(args, "universe", "Not A Name")) =~ "bad universe name"
      end
    end

    test "list_universes with none says so", %{conn: conn} do
      Kinoko.Repo.query!("delete from universes")
      assert ok!(conn, "list_universes", %{}) == "no universes"
    end

    test "the universe argument defaults to main", %{conn: conn} do
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
