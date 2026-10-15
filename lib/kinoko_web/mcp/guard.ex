defmodule KinokoWeb.Mcp.Guard do
  @moduledoc """
  Request checks for `/mcp`, before anything is dispatched (MCP 2025-06-18
  streamable HTTP, "Security Warning" and "Protocol Version Header"):

  - **Origin.** A request whose `Origin` is not a local host (`localhost`,
    `127.0.0.1`, `[::1]`) or the endpoint's configured url host is 403:
    a web page must not drive the code database through the browser
    (DNS rebinding, cross-site form posts). No `Origin` (a CLI or agent
    client) is allowed: the endpoint is local-only anyway.
  - **Content type.** A `POST` must be `application/json` (415 otherwise),
    so a browser cannot send it as a CORS "simple request" without a
    preflight, which this server never answers.
  - **Protocol version.** An `MCP-Protocol-Version` header naming a version
    this server does not speak is 400. Without the header the version
    negotiated at `initialize` (or the default) is assumed.

  Every refusal has a JSON-RPC error body with `id: null`.
  """

  @behaviour Plug

  import Plug.Conn

  alias KinokoWeb.Mcp.Protocol

  @local_hosts ["localhost", "127.0.0.1", "[::1]", "::1"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with :ok <- check_origin(conn),
         :ok <- check_content_type(conn),
         :ok <- check_protocol_version(conn) do
      conn
    else
      {:refuse, status, code, message} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(Protocol.error_response(nil, code, message)))
        |> halt()
    end
  end

  defp check_origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin | _] ->
        if allowed_origin?(origin),
          do: :ok,
          else: {:refuse, 403, -32600, "origin not allowed: #{origin}"}
    end
  end

  defp allowed_origin?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host in @local_hosts or host == configured_host()

      _ ->
        false
    end
  end

  defp configured_host, do: KinokoWeb.Endpoint.config(:url)[:host]

  defp check_content_type(%Plug.Conn{method: "POST"} = conn) do
    with [content_type | _] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _params} <- Plug.Conn.Utils.content_type(content_type) do
      :ok
    else
      _ -> {:refuse, 415, -32600, "POST /mcp must be Content-Type: application/json"}
    end
  end

  defp check_content_type(_conn), do: :ok

  defp check_protocol_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version | _] ->
        if version in Protocol.protocol_versions(),
          do: :ok,
          else:
            {:refuse, 400, -32600,
             "unsupported MCP-Protocol-Version: #{version} (supported: " <>
               Enum.join(Protocol.protocol_versions(), ", ") <> ")"}
    end
  end
end
