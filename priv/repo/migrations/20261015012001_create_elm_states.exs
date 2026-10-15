defmodule Kinoko.Repo.Migrations.CreateElmStates do
  use Ecto.Migration

  def change do
    create table(:elm_states, primary_key: false) do
      add :key, :text, null: false, primary_key: true
      add :seq, :bigint, null: false, primary_key: true
      add :version, :integer, null: false
      add :state, :binary, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end
  end
end
