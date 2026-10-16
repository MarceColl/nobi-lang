defmodule Kinoko.Release do
  @moduledoc """
  Release tasks. A release has no Mix, so run migrations with:

      bin/kinoko eval "Kinoko.Release.migrate()"

  The database is the SQLite file `$KINOKO_DATA/kinoko.db` (default
  `/var/lib/kinoko`); `migrate/0` creates the directory and the file first.
  """

  @app :kinoko

  @doc "Creates the data directory and runs every pending migration."
  @spec migrate() :: :ok
  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      ensure_data_dir(repo)

      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Creates the directory of `repo`'s SQLite file (SQLite makes the file, not the directory)."
  @spec ensure_data_dir(module()) :: :ok
  def ensure_data_dir(repo) do
    case Application.get_env(@app, repo, [])[:database] do
      path when is_binary(path) -> File.mkdir_p!(Path.dirname(path))
      _ -> :ok
    end
  end
end
