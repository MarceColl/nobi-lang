defmodule Nobi.Repo.Migrations.CreateDeclarations do
  use Ecto.Migration

  def change do
    create table(:declarations, primary_key: false) do
      add :cid, :text, primary_key: true, null: false
      add :text, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end
end
