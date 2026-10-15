defmodule KinokoWeb.DeploymentStatus do
  @moduledoc """
  Gives the static render of `KinokoWeb.DeploymentLive` its HTTP status: it
  resolves the host and the path the way the LiveView does and sets 404
  when nothing would be served (no deployment for the host, no route
  table, no route matching the path) and 503 when the deployment cannot
  run (for example a degraded universe). A served path keeps 200. The
  LiveView renders the page either way; only the status comes from here.
  """

  @behaviour Plug

  import Plug.Conn

  alias Kinoko.{Deployment, Universe}
  alias Kinoko.Lang.Routes

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case status(conn.host, conn.request_path) do
      :ok -> conn
      status -> put_status(conn, status)
    end
  end

  @doc "`:ok` when the deployment serves `path` on `host`, else the status to answer."
  @spec status(String.t(), String.t()) :: :ok | 404 | 503
  def status(host, path) do
    with {:ok, d} <- Deployment.resolve(host),
         {:ok, target} <- Deployment.target(d),
         tables when is_map(tables) <- Universe.routes(target),
         {:ok, entries} <- Map.fetch(tables, d.routes),
         {:ok, _app, _args} <- Routes.match(entries, path) do
      :ok
    else
      {:error, _} -> 503
      _miss -> 404
    end
  end
end
