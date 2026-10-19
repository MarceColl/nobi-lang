defmodule Nobi.Repo.Migrations.CreateWasmModules do
  use Ecto.Migration

  # WASM modules by content hash (`sha256:<hex>`). Append-only, like
  # `declarations`: a deployment pinned to a commit always calls the same bytes.
  def change do
    create table(:wasm_modules, primary_key: false) do
      add :hash, :text, primary_key: true, null: false
      add :bytes, :binary, null: false
      add :exports, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end
end
