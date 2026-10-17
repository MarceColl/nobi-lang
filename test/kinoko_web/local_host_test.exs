defmodule KinokoWeb.LocalHostTest do
  # Sets the app-wide :mode, so not async.
  use KinokoWeb.ConnCase, async: false

  alias KinokoWeb.LocalHost

  setup do
    previous = Application.fetch_env(:kinoko, :mode)
    Application.put_env(:kinoko, :mode, :local)

    on_exit(fn ->
      case previous do
        {:ok, mode} -> Application.put_env(:kinoko, :mode, mode)
        :error -> Application.delete_env(:kinoko, :mode)
      end
    end)
  end

  defp with_host(host), do: %{build_conn() | host: host}

  defp mcp_post(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}))
  end

  test "local_host?/1: loopback names only" do
    for host <- ~w(localhost 127.0.0.1 [::1] ::1 app.localhost a.b.localhost LOCALHOST) do
      assert LocalHost.local_host?(host), host
    end

    for host <- ["evil.example", "localhost.evil.example", "evillocalhost", ".localhost", "", nil] do
      refute LocalHost.local_host?(host), inspect(host)
    end
  end

  test "an allowed host is served: the console and /mcp" do
    assert with_host("localhost") |> get("/_") |> html_response(200)
    assert with_host("127.0.0.1") |> mcp_post() |> json_response(200)
  end

  test "a rebinding host is refused with a short 403" do
    conn = with_host("evil.example") |> get("/_")
    assert conn.status == 403
    assert conn.resp_body == "Kinoko answers only on localhost.\n"
    assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
  end

  test "/mcp under a foreign Host is refused, with or without an Origin" do
    assert with_host("evil.example") |> mcp_post() |> response(403)

    assert with_host("kinoko.example.com")
           |> put_req_header("origin", "http://localhost:4000")
           |> mcp_post()
           |> response(403)
  end

  test "the LiveView socket path is refused under a foreign Host" do
    conn = with_host("evil.example") |> get("/live/websocket")
    assert conn.status == 403
    assert conn.resp_body == "Kinoko answers only on localhost.\n"
  end

  test "outside local mode every host is served" do
    Application.put_env(:kinoko, :mode, :server)
    assert with_host("evil.example") |> mcp_post() |> json_response(200)
  end
end
