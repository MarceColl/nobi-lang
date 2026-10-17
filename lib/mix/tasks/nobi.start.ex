defmodule Mix.Tasks.Nobi.Start do
  @shortdoc "Starts Nobi: database, main universe, local deployment, server"

  @moduledoc """
  Starts Nobi in one command:

      mix nobi.start

  Creates and migrates the database, ensures the `main` universe and the
  `local` deployment, prints where everything is, then runs the server.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    boot()
    Nobi.Deployment.ensure_local()

    Mix.shell().info(Nobi.CLI.banner(NobiWeb.Endpoint.url()))
    # The endpoints already serve; this keeps the VM running (`--no-halt`).
    Mix.Tasks.Phx.Server.run(args)
  end

  @doc false
  # Asks Phoenix to serve the endpoints *before* the app starts them (an
  # endpoint reads `:serve_endpoints` once, when it starts; set after
  # `app.start` it never listens), then prepares the database and starts
  # the app. `run_task` is `Mix.Task.run/2`, swapped out in tests.
  @spec boot((String.t(), [String.t()] -> any)) :: :ok
  def boot(run_task \\ &Mix.Task.run/2) do
    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    run_task.("ecto.create", ["--quiet"])
    run_task.("ecto.migrate", ["--quiet"])
    run_task.("app.start", [])
    :ok
  end
end
