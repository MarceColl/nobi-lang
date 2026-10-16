defmodule Kinoko.Lang.Types.Evolution do
  @moduledoc """
  The model evolution rule: a stored model changes protobuf-style, add-only,
  because its rows outlive the code that wrote them.

  `errors/3` compares a declaration's new signature with the one committed
  under its name. When the committed one is a stored model
  (`Kinoko.Lang.Types.Store.stored?/1`):

  - every field it has keeps exactly its type, and stays;
  - every new field is an `Option<…>` or has a default.

  Changing or adding a default is allowed. Nothing committed, or a
  committed model that is not stored, constrains nothing: the rule applies
  from the first commit where the model is stored (a model that gains `id`
  starts it; one that loses `id` is removing a field). Every violation is a
  `"model-evolution"` error whose message names the fix.

  Only a model redefining a model is compared. Removing a stored model (a
  tombstone, or its name redefined as another kind) is not refused: its
  table stays as it is, and a model declared under the name later is a
  first commit again (decoding then reports, never guesses, what its old
  rows no longer fit).

  `Kinoko.Lang.Universe` applies it at promotion through its database
  (`Kinoko.Lang.Universe.Db`'s `{:evolution, cid}`), so it stays
  incremental; this module is the pure rule.
  """

  alias Kinoko.Lang.Format
  alias Kinoko.Lang.Types.Store

  @doc """
  The `"model-evolution"` errors of `name` redefined from `old` (its
  committed signature, or `nil`) to `new`: `[%{code, message}]`, in field
  order (the committed fields', then the new ones').
  """
  @spec errors(String.t(), term(), term()) :: [%{code: String.t(), message: String.t()}]
  def errors(name, old, new) do
    if Store.stored?(old) and match?({:model, _}, new),
      do: fields(name, elem(old, 1), elem(new, 1)),
      else: []
  end

  defp fields(name, old, new) do
    kept =
      Enum.flat_map(old, fn {f, t, _} ->
        case List.keyfind(new, f, 0) do
          {_, ^t, _} ->
            []

          {_, other, _} ->
            [
              error(
                "#{name}.#{f} was #{Format.type(t)}, cannot become #{Format.type(other)}; add a new " <>
                  "field instead"
              )
            ]

          nil ->
            [error("cannot remove #{name}.#{f}; leave it in place")]
        end
      end)

    added =
      for {f, t, :none} <- new,
          not List.keymember?(old, f, 0),
          not match?({:applied, "Option", [_]}, t) do
        decl = "#{f} : #{Format.type(t)}"

        error(
          "#{name}: new field #{decl} needs a default (#{decl} = #{suggest(t)}) or an Option type"
        )
      end

    kept ++ added
  end

  # A default of type `t` to show in the fix.
  defp suggest({:named, "Int"}), do: "0"
  defp suggest({:named, "String"}), do: ~s("")
  defp suggest({:named, "Bool"}), do: "false"
  defp suggest({:applied, "List", _}), do: "[]"
  defp suggest({:applied, "Map", _}), do: "%{}"
  defp suggest(_), do: "<a constant>"

  defp error(message), do: %{code: "model-evolution", message: message}
end
