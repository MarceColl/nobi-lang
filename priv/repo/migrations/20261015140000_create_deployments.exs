defmodule Kinoko.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:deployments, primary_key: false) do
      add :name, :text, primary_key: true
      add :universe, :text, null: false
      add :routes, :text, null: false
      # null: follow the universe's head
      add :commit, :integer
      add :hosts, {:array, :text}, null: false, default: []
      timestamps(type: :timestamptz)
    end
  end
end
