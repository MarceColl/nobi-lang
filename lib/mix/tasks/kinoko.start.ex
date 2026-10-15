defmodule Mix.Tasks.Kinoko.Start do
  @shortdoc "Starts Kinoko: database, main universe, local deployment, server"

  @moduledoc """
  Starts Kinoko in one command:

      mix kinoko.start

  Creates and migrates the database, ensures the `main` universe and the
  `local` deployment, prints where everything is, then runs the server.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    Kinoko.Deployment.ensure_local()

    Mix.shell().info(banner(KinokoWeb.Endpoint.url()))
    Mix.Tasks.Phx.Server.run(args)
  end

  @doc "The start-up banner for the endpoint at `base_url`."
  @spec banner(String.t()) :: String.t()
  def banner(base_url) do
    base = String.trim_trailing(base_url, "/")

    """

      Kinoko is running

        app       #{base}
        console   #{base}/_
        MCP       #{base}/mcp
    """
  end
end
