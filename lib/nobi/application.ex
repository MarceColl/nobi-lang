defmodule Nobi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    check_build()
    note_legacy_dev_data()
    Nobi.Release.ensure_data_dir(Nobi.Repo)

    children =
      [
        NobiWeb.Telemetry,
        Nobi.Repo,
        {Registry, keys: :unique, name: Nobi.Elm.Registry},
        # Home of PersistentElmGenServer.start/3. Those servers read the database on
        # boot, so during a DB outage they crash and fail to restart in a loop.
        # The tolerant intensity keeps that loop inside this supervisor instead
        # of exhausting it (and then Nobi.Supervisor, 3 restarts in 5 s) and
        # taking the whole application down.
        {DynamicSupervisor,
         name: Nobi.Elm.Supervisor, strategy: :one_for_one, max_restarts: 1_000, max_seconds: 60},
        # Nobi.Data: one opener per deployment file, found by its path in the
        # registry (which makes opening single-flight), and the schema cache.
        Nobi.Data.Cache,
        {Registry, keys: :unique, name: Nobi.Data.Registry},
        {DynamicSupervisor, name: Nobi.Data.Supervisor, strategy: :one_for_one},
        {DNSCluster, query: Application.get_env(:nobi, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Nobi.PubSub},
        # Owns the ETS table of Nobi.Universe.at/2's pinned views.
        Nobi.Universe.AtCache
        # One-shot: makes sure the `main` universe row exists. A DB outage is
        # logged, not fatal (the first Universe call retries ensure_main). Skipped
        # in test (`config :nobi, :ensure_main_at_boot, false`) because the SQL
        # sandbox owns connections there; tests call ensure_main explicitly.
      ] ++
        boot_tasks() ++
        [
          # Start a worker by calling: Nobi.Worker.start_link(arg)
          # {Nobi.Worker, arg},
          # Start to serve requests, typically the last entry
          NobiWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Nobi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Dev only (config/dev.exs): the checkout's data directory from before
  # Kinoko was renamed Nobi, until its database is moved.
  defp note_legacy_dev_data do
    with {old, new} <- Application.get_env(:nobi, :legacy_dev_data),
         note when is_binary(note) <- Nobi.Local.legacy_data_note(old, new) do
      Logger.warning(note)
    end

    :ok
  end

  defp boot_tasks do
    if Application.get_env(:nobi, :ensure_main_at_boot, true) do
      [
        Supervisor.child_spec({Task, &Nobi.Universe.Registry.ensure_main_at_boot/0},
          id: :ensure_main,
          restart: :temporary
        ),
        # Runs concurrently with :ensure_main (no ordering); ensure_local ensures
        # main itself. It does not repair a drifted existing `local` row.
        Supervisor.child_spec({Task, &Nobi.Deployment.ensure_local_at_boot/0},
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
    case Application.get_env(:nobi, :mode) do
      nil -> :ok
      mode -> Nobi.Local.check_build!(mode, Application.get_env(:nobi, :mcp_enabled, false))
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NobiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
