defmodule Kinoko.Lang.Types.Hints do
  @moduledoc """
  What a name that did not resolve says (ported from `types/check/hints.rs`):
  the misuse-hint chain down to "unbound symbol" (TS's `declFor`,
  `siblings` and `unboundMessage`), and an unknown type's message.

  "unbound symbol" is the truth only when nothing by that name exists. When
  the name is a declaration the checker can see, the message says what it
  is and the shape that works. An agent once spent a session guessing
  constructors for a model (`.new`, `.create`, positional calls) because
  every attempt came back "unbound symbol".

  Every lookup here is a diagnostic peek, deliberately not `Ctx.dget/2`:
  what a diagnostic found is not a dependency. Peeks need the whole table
  (a map). A check against a lookup function has none, so its messages say
  less (Rust's `Table::whole`).
  """

  alias Kinoko.Lang.Ast
  alias Kinoko.Lang.Types.Check.Ctx
  alias Kinoko.Lang.Types.{Extract, Stdlib}

  @doc """
  What `name`, which did not resolve, says: what it is when it is a
  declaration; what the writer probably meant when something close is; what
  its namespace does have; and only when nothing at all is there, that it is
  unbound. `as_value` is whether `name` stands as a value rather than a
  call's target. Returns `{message, ctx}`.
  """
  def unbound_message(ctx, name, as_value) do
    {said, ctx} =
      case ctx.table_says do
        %{^name => said} ->
          {said, ctx}

        _ ->
          {said, ctx} = what_the_table_says(ctx, name)
          {said, %{ctx | table_says: Map.put(ctx.table_says, name, said)}}
      end

    message =
      said || (as_value && local_field_hint(ctx, name)) || "unbound symbol `#{name}`"

    {message, ctx}
  end

  @doc "An annotation's type `name` resolves to nothing."
  def unknown_type(name) do
    if Ast.capitalised?(name) do
      "unknown type `#{name}`"
    else
      "unknown type `#{name}` — an annotation names concrete types; `#{name}` in an answer means any type " <>
        "and cannot be written"
    end
  end

  # What the table says of `name`: what it is, or is close to, or what its
  # namespace has; nil when it says none of those.
  defp what_the_table_says(%Ctx{sigs: sigs} = ctx, name) when is_map(sigs) do
    case decl_for(ctx, sigs, name) do
      {{found, sig}, ctx} ->
        hint = misuse_hint(found, sig)
        {if(found == name, do: hint, else: "`#{name}` is not in scope — #{hint}"), ctx}

      {nil, ctx} ->
        case siblings(sigs, name) do
          [] ->
            {nil, ctx}

          near ->
            shown = near |> Enum.take(8) |> Enum.map_join(", ", &"`#{&1}`")
            more = if length(near) > 8, do: ", …", else: ""
            {"there is no `#{name}` — `#{Extract.owner_of(name)}` has #{shown}#{more}", ctx}
        end
    end
  end

  defp what_the_table_says(ctx, _name), do: {nil, ctx}

  # Three ways to find what the writer meant: the name itself; its owner,
  # which turns a guessed member (`Game.Board.new`) into the model it hangs
  # off; and a case-insensitive match of the whole name or, for an undotted
  # name, of any declaration's last segment.
  defp decl_for(ctx, sigs, name) do
    dotted = String.contains?(name, ".")
    owner = Extract.owner_of(name)

    cond do
      Map.has_key?(sigs, name) ->
        {{name, sigs[name]}, ctx}

      dotted and Map.has_key?(sigs, owner) ->
        {{owner, sigs[owner]}, ctx}

      true ->
        index = ctx.names || name_index(sigs)
        ctx = %{ctx | names: index}

        case close(index, String.downcase(name), dotted) do
          nil -> {nil, ctx}
          found -> {{found, sigs[found]}, ctx}
        end
    end
  end

  # What does exist under `name`'s namespace: the first nine, sorted.
  defp siblings(sigs, name) do
    if String.contains?(name, ".") do
      prefix = Extract.owner_of(name) <> "."

      sigs
      |> Map.keys()
      |> Enum.filter(&(String.starts_with?(&1, prefix) and &1 != name))
      |> Enum.sort()
      |> Enum.take(9)
    else
      []
    end
  end

  # A Rust addition, the last resort before "unbound": a capitalised head
  # reads every `.ident` after it as one dotted name, so `M.x` with `M` a
  # local is that name, never a field of `M`; `(M).x` is the field.
  defp local_field_hint(ctx, name) do
    with [root, rest] <- String.split(name, ".", parts: 2),
         t when t != nil <- Ctx.lookup_local(ctx, root) do
      "`#{name}` is not in scope — `#{root}` is a local, but `#{name}` reads as one dotted name, not a field of " <>
        "it: write `(#{root}).#{rest}`"
    else
      _ -> nil
    end
  end

  # Every declaration by its name lowercased, whole and by its last segment.
  # Each key holds the first declaration to have it in TS's table order: the
  # stdlib first, in its declared order, then the program's own, sorted. So
  # `get` is `Cmd.store.get`, not `Cmd.blob.get`.
  defp name_index(sigs) do
    stdlib = Stdlib.signatures()
    from_stdlib = Enum.filter(Stdlib.names(), &Map.has_key?(sigs, &1))
    from_program = sigs |> Map.keys() |> Enum.reject(&Map.has_key?(stdlib, &1)) |> Enum.sort()

    (from_stdlib ++ from_program)
    |> Enum.with_index()
    |> Enum.reduce(%{whole: %{}, last: %{}}, fn {name, rank}, index ->
      %{
        whole: Map.put_new(index.whole, String.downcase(name), {rank, name}),
        last: Map.put_new(index.last, String.downcase(Extract.last_segment(name)), {rank, name})
      }
    end)
  end

  defp close(index, lower, dotted) do
    by_last = if dotted, do: nil, else: index.last[lower]

    case Enum.reject([index.whole[lower], by_last], &is_nil/1) do
      [] -> nil
      found -> found |> Enum.min() |> elem(1)
    end
  end

  @doc """
  What declaration `found`, of signature `sig`, used where it cannot be,
  says it is, with the shape that works (TS's `misuseHint`).
  """
  def misuse_hint(found, sig)

  def misuse_hint(found, {:model, fields}) do
    data = for {name, t} <- fields, not (name == "id" and t == {:named, "Uuid"}), do: name
    inits = Enum.map_join(data, ", ", &"#{&1}: …")
    one = List.first(data, "field")

    "`#{found}` is a model, not a function — construct it with `%#{found}{#{inits}}`, update one with " <>
      "`%#{found}{row | #{one}: …}`"
  end

  def misuse_hint(found, {:type, _, []}),
    do: "`#{found}` is a type, not a value, and has no variants"

  def misuse_hint(found, {:type, _, variants}) do
    shown = Enum.map_join(variants, ", ", fn {v, _} -> "`#{found}.#{v}`" end)
    "`#{found}` is a type, not a value — its values are its variants: #{shown}"
  end

  def misuse_hint(found, :app),
    do: "`#{found}` is an app — an app is entered by navigation, not referenced as a value"

  def misuse_hint(found, :test), do: "`#{found}` is a test, not a value"

  def misuse_hint(found, {:def, _, _}),
    do: "`#{found}` is what you want — every name is fully qualified, so write `#{found}`"
end
