defmodule Kinoko.Repo.Migrations.CreateDeclarations do
  use Ecto.Migration

  def change do
    create table(:declarations, primary_key: false) do
      add :cid, :text, primary_key: true
      add :text, :text, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end
  end
end
