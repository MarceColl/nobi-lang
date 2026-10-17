defmodule NobiWeb.McpRaisingTools do
  @moduledoc """
  A tools module for the MCP tests whose tools raise or exit, to prove
  `NobiWeb.Mcp.Protocol` turns either into an `isError` result.
  Installed per request with `put_private(conn, :mcp_tools, __MODULE__)`.
  """

  def list, do: []

  def call("boom", _args), do: raise("kaboom")
  def call("exit", _args), do: exit(:kaput)
  def call(_name, _args), do: {:error, :unknown_tool}
end
