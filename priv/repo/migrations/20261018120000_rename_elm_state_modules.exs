defmodule Nobi.Repo.Migrations.RenameElmStateModules do
  use Ecto.Migration

  # The project was called Kinoko. Each elm_states row names the module that
  # wrote it (`inspect/1`, e.g. "Kinoko.CodeDb"), and a server refuses rows
  # written by another module, so rows written before the rename get their
  # writer's new name. Self-contained: it must mean the same whatever the
  # modules become.
  @renames [{"Kinoko.", "Nobi."}, {"KinokoWeb.", "NobiWeb."}]

  def up, do: rename_modules(repo(), @renames)

  def down, do: rename_modules(repo(), Enum.map(@renames, fn {old, new} -> {new, old} end))

  @doc false
  # Renames the `module` of every row under one of `renames`' prefixes and
  # returns how many rows changed. GLOB, unlike LIKE, is case-sensitive.
  def rename_modules(repo, renames) do
    Enum.sum_by(renames, fn {from, to} ->
      %{num_rows: n} =
        repo.query!(
          "UPDATE elm_states SET module = ? || substr(module, ?) WHERE module GLOB ?",
          [to, String.length(from) + 1, from <> "*"]
        )

      n
    end)
  end
end
