defmodule Kinoko.Repo.Migrations.AddModuleToElmStates do
  use Ecto.Migration

  # The module that wrote each row, as its name string (never turned back
  # into an atom). Nothing is deployed yet, so existing rows get ''.
  def change do
    alter table(:elm_states) do
      add :module, :text, null: false, default: ""
    end
  end
end
