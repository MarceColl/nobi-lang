defmodule NobiWeb.DeploymentStatus do
  @moduledoc """
  The request side of `NobiWeb.DeploymentLive`.

  As a plug, it resolves the deployment the request's host reaches (once,
  kept in `conn.private`) and gives the static render its HTTP status: 404
  when nothing would be served (no deployment for the host, no route
  table, no route matching the path) and 503 when the deployment cannot
  run (for example a degraded universe). A served path keeps 200. The
  LiveView renders the page either way; only the status comes from here.

  `session/1` is the `live_session`'s session callback: it puts the
  resolved deployment's name (and the host, for the "nothing here" page)
  in the signed LiveView session. The connected LiveView serves that name
  and never resolves a host the client sends.
  """

  @behaviour Plug

  import Plug.Conn

  alias Nobi.{Deployment, Universe}
  alias Nobi.Lang.Routes

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    deployment = resolve(conn.host)
    conn = put_private(conn, :nobi_deployment, deployment)

    case status(deployment, conn.request_path) do
      :ok -> conn
      status -> put_status(conn, status)
    end
  end

  @doc "The LiveView session for `conn`: `%{\"deployment\" => name | nil, \"host\" => host}`."
  @spec session(Plug.Conn.t()) :: map()
  def session(conn) do
    deployment =
      case Map.fetch(conn.private, :nobi_deployment) do
        {:ok, d} -> d
        :error -> resolve(conn.host)
      end

    %{"deployment" => deployment && deployment.name, "host" => conn.host}
  end

  defp resolve(host) do
    case Deployment.resolve(host) do
      {:ok, d} -> d
      :error -> nil
    end
  end

  @doc "`:ok` when `deployment` serves `path`, else the status to answer."
  @spec status(Deployment.t() | nil, String.t()) :: :ok | 404 | 503
  def status(nil, _path), do: 404

  def status(deployment, path) do
    with {:ok, target} <- Deployment.target(deployment),
         tables when is_map(tables) <- Universe.routes(target),
         {:ok, entries} <- Map.fetch(tables, deployment.routes),
         {:ok, _app, _args} <- Routes.match(entries, path) do
      :ok
    else
      {:error, _} -> 503
      _miss -> 404
    end
  end
end
