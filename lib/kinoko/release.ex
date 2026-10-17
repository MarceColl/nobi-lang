defmodule Kinoko.Release do
  @moduledoc """
  Release tasks. A release has no Mix, so run migrations with:

      bin/kinoko eval "Kinoko.Release.migrate()"

  The database is the SQLite file `$KINOKO_DATA/kinoko.db` (default
  `~/.kinoko` in local mode, `/var/lib/kinoko` with `KINOKO_MODE=server`;
  see `Kinoko.Local`); `migrate/0` creates the directory and the file first.
  `start/0` migrates on its own (`kinoko start`).
  """

  @app :kinoko

  @doc """
  Starts Kinoko from a release with no Mix: migrates, makes the endpoint
  serve, starts the application, then ensures the `main` universe and the
  `local` deployment (what `mix kinoko.start` does). `kinoko start` runs it.
  """
  @spec start() :: :ok
  def start do
    :ok = migrate()
    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    {:ok, _} = Application.ensure_all_started(@app)
    Kinoko.Deployment.ensure_local()
  end

  @doc "Creates the data directory and runs every pending migration."
  @spec migrate() :: :ok
  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      ensure_data_dir(repo)

      # One connection: on a fresh file, a pool opening at once races to set
      # WAL mode and logs "database is locked".
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true), pool_size: 1)
    end

    :ok
  end

  @doc "Creates the directory of `repo`'s SQLite file (SQLite makes the file, not the directory)."
  @spec ensure_data_dir(module()) :: :ok
  def ensure_data_dir(repo) do
    case data_dir(repo) do
      nil -> :ok
      dir -> File.mkdir_p!(dir)
    end
  end

  @doc "The directory of `repo`'s SQLite file, or `nil` when none is configured."
  @spec data_dir(module()) :: String.t() | nil
  def data_dir(repo) do
    case Application.get_env(@app, repo, [])[:database] do
      path when is_binary(path) -> Path.dirname(path)
      _ -> nil
    end
  end
end
