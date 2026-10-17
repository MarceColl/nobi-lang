defmodule KinokoWeb.McpController do
  @moduledoc """
  `POST /mcp`: the MCP streamable-HTTP transport with plain JSON answers
  (no SSE, no session id). The body is read here, unparsed by the
  endpoint, so `KinokoWeb.Mcp.Protocol` can answer malformed JSON with a
  JSON-RPC parse error. `GET` (the optional server-to-client stream) and
  `DELETE` (session end) are 405: this server has neither.

  ## Mounted only where enabled

  The endpoint has **no authentication yet** (deferred: per-caller keys
  come later), and every tool can change a universe, `"main"` included. So
  the router mounts `/mcp` only when
  `Application.compile_env(:kinoko, :mcp_enabled, false)` is true:
  `config/dev.exs` and `config/test.exs` set it, and so does the local
  prod build (the `kinoko` binary, which binds 127.0.0.1); a server build
  (`KINOKO_BUILD=server`) leaves it off, and there `/mcp` is a 404. It is read at compile time: changing it needs a
  recompile of the router.
  """

  use KinokoWeb, :controller

  alias KinokoWeb.Mcp.Protocol

  # As Plug.Parsers' default limit.
  @max_body 8_000_000

  def post(conn, _params) do
    case read_body(conn, length: @max_body) do
      {:ok, body, conn} ->
        answer(conn, Protocol.handle(body, tools: tools(conn)))

      {:more, _partial, conn} ->
        conn
        |> put_status(413)
        |> json(
          Protocol.error_response(nil, -32600, "request body larger than #{@max_body} bytes")
        )

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(
          Protocol.error_response(nil, -32700, "could not read the body: #{inspect(reason)}")
        )
    end
  end

  def not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  defp answer(conn, :accepted), do: send_resp(conn, 202, "")
  defp answer(conn, {:reply, status, body}), do: conn |> put_status(status) |> json(body)

  # Tests swap in other tools (`put_private(conn, :mcp_tools, mod)`);
  # nothing a client sends can set a private.
  defp tools(conn), do: Map.get(conn.private, :mcp_tools, KinokoWeb.Mcp.Tools)
end
