defmodule Kinoko.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    check_build()
    Kinoko.Release.ensure_data_dir(Kinoko.Repo)

    children =
      [
        KinokoWeb.Telemetry,
        Kinoko.Repo,
        {Registry, keys: :unique, name: Kinoko.Elm.Registry},
        # Home of PersistentElmGenServer.start/3. Those servers read the database on
        # boot, so during a DB outage they crash and fail to restart in a loop.
        # The tolerant intensity keeps that loop inside this supervisor instead
        # of exhausting it (and then Kinoko.Supervisor, 3 restarts in 5 s) and
        # taking the whole application down.
        {DynamicSupervisor,
         name: Kinoko.Elm.Supervisor, strategy: :one_for_one, max_restarts: 1_000, max_seconds: 60},
        # Kinoko.Data: one opener per deployment file, found by its path in the
        # registry (which makes opening single-flight), and the schema cache.
        Kinoko.Data.Cache,
        {Registry, keys: :unique, name: Kinoko.Data.Registry},
        {DynamicSupervisor, name: Kinoko.Data.Supervisor, strategy: :one_for_one},
        {DNSCluster, query: Application.get_env(:kinoko, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Kinoko.PubSub},
        # Owns the ETS table of Kinoko.Universe.at/2's pinned views.
        Kinoko.Universe.AtCache
        # One-shot: makes sure the `main` universe row exists. A DB outage is
        # logged, not fatal (the first Universe call retries ensure_main). Skipped
        # in test (`config :kinoko, :ensure_main_at_boot, false`) because the SQL
        # sandbox owns connections there; tests call ensure_main explicitly.
      ] ++
        boot_tasks() ++
        [
          # Start a worker by calling: Kinoko.Worker.start_link(arg)
          # {Kinoko.Worker, arg},
          # Start to serve requests, typically the last entry
          KinokoWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kinoko.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp boot_tasks do
    if Application.get_env(:kinoko, :ensure_main_at_boot, true) do
      [
        Supervisor.child_spec({Task, &Kinoko.Universe.Registry.ensure_main_at_boot/0},
          id: :ensure_main,
          restart: :temporary
        ),
        # Runs concurrently with :ensure_main (no ordering); ensure_local ensures
        # main itself. It does not repair a drifted existing `local` row.
        Supervisor.child_spec({Task, &Kinoko.Deployment.ensure_local_at_boot/0},
          id: :ensure_local,
          restart: :temporary
        )
      ]
    else
      []
    end
  end

  # A prod release names its run mode (config/runtime.exs); refuse a build
  # that does not fit it, e.g. a server exposing the unauthenticated /mcp.
  defp check_build do
    case Application.get_env(:kinoko, :mode) do
      nil -> :ok
      mode -> Kinoko.Local.check_build!(mode, Application.get_env(:kinoko, :mcp_enabled, false))
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KinokoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
