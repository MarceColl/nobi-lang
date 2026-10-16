defmodule Kinoko.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:deployments, primary_key: false) do
      add :name, :text, primary_key: true, null: false
      add :universe, :text, null: false
      add :routes, :text, null: false
      # null: follow the universe's head
      add :commit, :integer
      timestamps(type: :utc_datetime_usec)
    end

    # The exact (normalised) hostnames that reach a deployment. `position`
    # keeps them in the order they were given (the first is the primary).
    create table(:deployment_hosts, primary_key: false) do
      add :deployment,
          references(:deployments, column: :name, type: :text, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :host, :text, primary_key: true, null: false
      add :position, :integer, null: false
    end

    create index(:deployment_hosts, [:host])
  end
end
