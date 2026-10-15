defmodule Kinoko.Repo.Migrations.CreateUniverses do
  use Ecto.Migration

  def change do
    create table(:universes, primary_key: false) do
      add :name, :text, primary_key: true
      add :parent, :text
      add :forked_at_commit, :integer
      add :created_at, :timestamptz, null: false, default: fragment("now()")
    end
  end
end
