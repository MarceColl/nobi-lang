defmodule Nobi.RenameElmStateModulesTest do
  use Nobi.DataCase, async: false

  alias Nobi.Elm.Store

  @migration "priv/repo/migrations/20261018120000_rename_elm_state_modules.exs"

  # Loaded from its file at run time, as `mix ecto.migrate` loads it.
  defp migration do
    mod = Nobi.Repo.Migrations.RenameElmStateModules
    unless Code.ensure_loaded?(mod), do: Code.require_file(@migration)
    mod
  end

  defp rename_modules(renames), do: apply(migration(), :rename_modules, [Nobi.Repo, renames])

  defp module_of(key) do
    {:ok, %{module: module}} = Store.latest(key)
    module
  end

  test "rows written under the old project name get the new module names" do
    rows = [
      {"rename:codedb", "Kinoko.CodeDb"},
      {"rename:web", "KinokoWeb.Something"},
      {"rename:lower", "kinoko.CodeDb"},
      {"rename:prefix", "KinokoExtra.X"},
      {"rename:other", "Demo.PersistentCounter"}
    ]

    for {key, module} <- rows, do: Store.append(key, 1, module, 1, "state")

    assert rename_modules([
             {"Kinoko.", "Nobi."},
             {"KinokoWeb.", "NobiWeb."}
           ]) ==
             2

    assert module_of("rename:codedb") == "Nobi.CodeDb"
    assert module_of("rename:web") == "NobiWeb.Something"
    assert module_of("rename:lower") == "kinoko.CodeDb"
    assert module_of("rename:prefix") == "KinokoExtra.X"
    assert module_of("rename:other") == "Demo.PersistentCounter"
  end
end
