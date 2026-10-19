defmodule Nobi.Lang.Types.Evolution do
  @moduledoc """
  The model evolution rule: a stored model changes protobuf-style, add-only,
  because its rows outlive the code that wrote them.

  `errors/3` compares a declaration's new signature with the one committed
  under its name. When the committed one is a stored model
  (`Nobi.Lang.Types.Store.stored?/1`):

  - every field it has keeps exactly its type, and stays;
  - every new field is an `Option<…>` or has a default.

  Changing or adding a default is allowed. Nothing committed, or a
  committed model that is not stored, constrains nothing: the rule applies
  from the first commit where the model is stored (a model that gains `id`
  starts it; one that loses `id` is removing a field). Every violation is a
  `"model-evolution"` error whose message names the fix.

  The rule reaches through a stored model's field types: every model and
  deftype reachable from them (inside `List`, `Option`, `Map`, tuples,
  deftype variants, other models) is stored inside its rows (`check/5`).
  Such a model's committed fields are held to the same rule, stored itself
  or not. Such a deftype keeps its type parameters and every variant with
  exactly its payload types; it may only gain variants. A model or deftype
  no stored model reaches evolves freely. (The stdlib's `Option` and
  `Result` have no committed version and are never compared.)

  Only a model redefining a model is compared. Removing a stored model (a
  tombstone, or its name redefined as another kind) is not refused: its
  table stays as it is, and a model declared under the name later is a
  first commit again (decoding then reports, never guesses, what its old
  rows no longer fit).

  `Nobi.Lang.Universe` applies it at promotion through its database
  (`Nobi.Lang.Universe.Db`'s `{:evolution, cid}`), so it stays
  incremental; this module is the pure rule.
  """

  alias Nobi.Lang.Format
  alias Nobi.Lang.Types.{Extract, Store}

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

  @doc """
  The whole rule for the model `name`, its signature `new` in the image
  being checked, `old` the one committed (or `nil`): `errors/3`, then, when
  `old` is stored, `errors` for every other model `new`'s fields reach
  (`lookup` gives an image signature, `committed` a committed one, each by
  name, `nil` for none). Returns `{errors, reached}`, `reached` every name
  whose image signature the reach read (models and deftypes) whenever
  `new` or `old` is stored, so a caller can depend on them.
  """
  @spec check(String.t(), term(), term(), (String.t() -> term()), (String.t() -> term())) ::
          {[%{code: String.t(), message: String.t()}], [String.t()]}
  def check(name, old, new, lookup, committed) do
    own = errors(name, old, new)

    # A stored model reaches what its fields do even on its first commit,
    # so a later patch to what it reaches checks it again.
    if Store.stored?(new) or (Store.stored?(old) and match?({:model, _}, new)) do
      {kept, reached} = reach(new, lookup)

      nested =
        for n <- kept,
            Store.stored?(old),
            n != name,
            e <- inside(n, committed.(n), lookup.(n)),
            do: %{e | message: e.message <> " (#{n} is kept inside the stored model #{name})"}

      {own ++ nested, reached}
    else
      {own, []}
    end
  end

  # A model or deftype kept inside a stored model's rows, against its
  # committed signature: a model's fields as a stored model's; a deftype's
  # parameters and every variant's payload kept, variants only added.
  defp inside(n, {:model, before}, {:model, now}), do: fields(n, before, now)

  defp inside(n, {:type, ps, before}, {:type, qs, now}) do
    params =
      if ps == qs,
        do: [],
        else: [
          error(
            "#{n} had type parameters #{params(ps)}, cannot become #{params(qs)}; declare a new " <>
              "type instead"
          )
        ]

    params ++
      Enum.flat_map(before, fn {v, args} ->
        case List.keyfind(now, v, 0) do
          {_, ^args} ->
            []

          {_, other} ->
            [
              error(
                "#{n}.#{v} had #{payload(args)}, cannot become #{payload(other)}; add a new variant " <>
                  "instead"
              )
            ]

          nil ->
            [error("cannot remove #{n}.#{v}; leave it in place")]
        end
      end)
  end

  defp inside(_n, _before, _now), do: []

  defp params([]), do: "<>"
  defp params(ps), do: "<#{Enum.join(ps, ", ")}>"

  defp payload(args), do: "(#{Enum.map_join(args, ", ", &Format.type/1)})"

  # The models and deftypes `sig`'s fields reach, in the order met, and
  # every name read.
  defp reach({:model, fields}, lookup) do
    {kept, seen} = walk(Enum.map(fields, &elem(&1, 1)), lookup, [], MapSet.new())
    {Enum.reverse(kept), seen |> MapSet.to_list() |> Enum.sort()}
  end

  defp walk([], _lookup, models, seen), do: {models, seen}

  defp walk([t | rest], lookup, models, seen) do
    case t do
      {:named, n} -> visit(n, [], rest, lookup, models, seen)
      {:applied, n, args} -> visit(n, args, rest, lookup, models, seen)
      {:arrow, ps, r} -> walk([r | ps] ++ rest, lookup, models, seen)
      {:tuple, items} -> walk(items ++ rest, lookup, models, seen)
      _ -> walk(rest, lookup, models, seen)
    end
  end

  defp visit(n, args, rest, lookup, models, seen) do
    builtin? = n in Extract.builtin_named() or Map.has_key?(Extract.builtin_applied(), n)

    if builtin? or MapSet.member?(seen, n) do
      walk(args ++ rest, lookup, models, seen)
    else
      seen = MapSet.put(seen, n)

      case lookup.(n) do
        {:model, fs} ->
          walk(args ++ Enum.map(fs, &elem(&1, 1)) ++ rest, lookup, [n | models], seen)

        {:type, _, variants} ->
          walk(args ++ Enum.flat_map(variants, &elem(&1, 1)) ++ rest, lookup, [n | models], seen)

        _ ->
          walk(args ++ rest, lookup, models, seen)
      end
    end
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
  defp suggest({:named, "Float"}), do: "0.0"
  defp suggest({:named, "String"}), do: ~s("")
  defp suggest({:named, "Bool"}), do: "false"
  defp suggest({:applied, "List", _}), do: "[]"
  defp suggest({:applied, "Map", _}), do: "%{}"
  defp suggest(_), do: "<a constant>"

  defp error(message), do: %{code: "model-evolution", message: message}
end
