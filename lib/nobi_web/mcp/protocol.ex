defmodule NobiWeb.Mcp.Protocol do
  @moduledoc """
  MCP's JSON-RPC 2.0 layer, with no `Plug.Conn`: decode one HTTP body,
  dispatch it, and say what to answer.

  - One request object gets a response object. A notification (no `id`),
    or a response the client sends back, is `:accepted` (HTTP 202, no body).
  - A body that is not JSON is `-32700`; a batch array, or anything that is
    not a JSON-RPC 2.0 message, is `-32600`. Both have `id: null` and HTTP 400.
    (MCP 2025-06-18 dropped batching, so a batch is refused, not run, even
    for a client that negotiated 2025-03-26, which still allowed batches.)
  - An unknown method is `-32601`. Params of the wrong shape and an unknown
    tool are `-32602`.
  - A tool that raises or exits answers an `isError` result naming what
    went wrong: it never escapes to become an HTTP 500.

  The tools come from `opts[:tools]` (default `NobiWeb.Mcp.Tools`), a
  module with `list/0` and `call/2`.
  """

  require Logger

  alias NobiWeb.Mcp.{Instructions, Tools}

  @protocol_versions ["2025-06-18", "2025-03-26", "2024-11-05"]
  @latest "2025-06-18"

  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602

  @doc "The protocol versions this server speaks, newest first."
  @spec protocol_versions() :: [String.t()]
  def protocol_versions, do: @protocol_versions

  @type answer :: {:reply, 200 | 400, map()} | :accepted

  @doc "Decode `body`, dispatch it, and give the HTTP answer."
  @spec handle(binary(), keyword()) :: answer
  def handle(body, opts \\ []) do
    case Jason.decode(body) do
      {:ok, message} ->
        handle_message(message, Keyword.get(opts, :tools, Tools))

      {:error, error} ->
        {:reply, 400,
         error_response(nil, @parse_error, "Parse error: " <> Exception.message(error))}
    end
  end

  @doc "The JSON-RPC error object for a request that never reached dispatch."
  @spec error_response(term(), integer(), String.t()) :: map()
  def error_response(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp handle_message(batch, _tools) when is_list(batch),
    do: {:reply, 400, error_response(nil, @invalid_request, "batch requests are not supported")}

  defp handle_message(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = msg, tools)
       when is_binary(method) and (is_binary(id) or is_integer(id)) do
    response =
      case dispatch(method, Map.get(msg, "params", %{}), tools) do
        {:ok, result} -> %{jsonrpc: "2.0", id: id, result: result}
        {:error, code, message} -> error_response(id, code, message)
      end

    {:reply, 200, response}
  end

  # A notification, which gets no answer.
  defp handle_message(%{"jsonrpc" => "2.0", "method" => method} = msg, _tools)
       when is_binary(method) and not is_map_key(msg, "id"),
       do: :accepted

  # A response to a request of ours (we send none): nothing to say.
  defp handle_message(%{"jsonrpc" => "2.0", "id" => _} = msg, _tools)
       when is_map_key(msg, "result") or is_map_key(msg, "error"),
       do: :accepted

  defp handle_message(msg, _tools) do
    id = if is_map(msg) and (is_binary(msg["id"]) or is_integer(msg["id"])), do: msg["id"]
    {:reply, 400, error_response(id, @invalid_request, "not a JSON-RPC 2.0 request")}
  end

  defp dispatch("initialize", params, _tools) when is_map(params) do
    requested = params["protocolVersion"]

    {:ok,
     %{
       protocolVersion: if(requested in @protocol_versions, do: requested, else: @latest),
       serverInfo: %{name: "nobi", version: version()},
       capabilities: %{tools: %{}},
       instructions: Instructions.text()
     }}
  end

  defp dispatch("ping", _params, _tools), do: {:ok, %{}}

  defp dispatch("tools/list", params, tools) when is_map(params),
    do: {:ok, %{tools: tools.list()}}

  defp dispatch("tools/call", %{"name" => name} = params, tools) when is_binary(name) do
    case Map.get(params, "arguments", %{}) do
      args when is_map(args) -> call_tool(tools, name, args)
      _ -> {:error, @invalid_params, "tools/call `arguments` must be an object"}
    end
  end

  defp dispatch("tools/call", _params, _tools),
    do: {:error, @invalid_params, "tools/call needs a `name` (string) and `arguments` (object)"}

  defp dispatch(method, params, _tools)
       when method in ["initialize", "tools/list"] and not is_map(params),
       do: {:error, @invalid_params, "#{method} params must be an object"}

  defp dispatch(method, _params, _tools),
    do: {:error, @method_not_found, "method not found: #{method}"}

  defp call_tool(tools, name, args) do
    case guarded(fn -> tools.call(name, args) end) do
      {:error, :unknown_tool} -> {:error, @invalid_params, "unknown tool: #{name}"}
      {:ok, result} -> {:ok, result}
    end
  end

  # A tool is `{:ok, result} | {:error, :unknown_tool}`; whatever escapes it
  # becomes an isError result.
  defp guarded(fun) do
    fun.()
  rescue
    e ->
      Logger.error("MCP tool raised: " <> Exception.format(:error, e, __STACKTRACE__))
      {:ok, Tools.error_result("internal error: " <> Exception.message(e))}
  catch
    kind, reason ->
      Logger.error("MCP tool failed: " <> Exception.format(kind, reason, __STACKTRACE__))
      {:ok, Tools.error_result("internal error: " <> Exception.format_banner(kind, reason))}
  end

  defp version, do: Application.spec(:nobi, :vsn) |> to_string()
end
