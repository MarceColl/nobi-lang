defmodule Nobi.Repo.Migrations.CreateUniverses do
  use Ecto.Migration

  def change do
    create table(:universes, primary_key: false) do
      add :name, :text, primary_key: true, null: false
      add :parent, :text
      add :forked_at_commit, :integer
      add :created_at, :utc_datetime_usec, null: false
    end
  end
end
