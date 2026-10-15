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
  less (Rust's `Table::whole`); `reword/2` gives such a message what the
  whole table says, exactly as a check against the table would have.

  The whole table is `table/1`: the signatures, their names sorted (for
  `siblings`) and indexed by lowercased name (for `decl_for`). Building it
  is linear-logarithmic in the table, so it is built once per table and
  shared by every check against it (`Ctx.new/2`'s `table:`), never once per
  check that meets an unbound name.
  """

  @typedoc "The whole table: `sigs`, its names sorted, and its name index."
  @type table :: %{sigs: map(), sorted: tuple(), names: map()}

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

  @doc "The whole table of `sigs` (a map), for `says/2`, `reword/2` and `Ctx.new/2`."
  @spec table(map()) :: table()
  def table(sigs) when is_map(sigs),
    do: %{
      sigs: sigs,
      sorted: sigs |> Map.keys() |> Enum.sort() |> List.to_tuple(),
      names: name_index(sigs)
    }

  @doc """
  What the whole table says of `name`, which did not resolve: what it is,
  or is close to, or what its namespace has; `nil` when it says none of
  those (the message is then a lookup check's: a local's hint, or "unbound").
  """
  @spec says(table(), String.t()) :: String.t() | nil
  def says(table, name) do
    case decl_for(table, name) do
      {found, sig} ->
        hint = misuse_hint(found, sig)
        if found == name, do: hint, else: "`#{name}` is not in scope — #{hint}"

      nil ->
        case siblings(table, name) do
          [] ->
            nil

          near ->
            shown = near |> Enum.take(8) |> Enum.map_join(", ", &"`#{&1}`")
            more = if length(near) > 8, do: ", …", else: ""
            "there is no `#{name}` — `#{Extract.owner_of(name)}` has #{shown}#{more}"
        end
    end
  end

  @doc """
  The message a check against the whole table gives an `"unbound"` error
  about `name` that a check against a lookup function worded `message`: a
  table check says what the table says, when it says anything, and
  otherwise exactly what the lookup check said.
  """
  @spec reword(table(), %{message: String.t(), unbound: String.t() | nil}) :: String.t()
  def reword(_table, %{unbound: nil, message: message}), do: message
  def reword(table, %{unbound: name, message: message}), do: says(table, name) || message

  @doc "An annotation's type `name` resolves to nothing."
  def unknown_type(name) do
    if Ast.capitalised?(name) do
      "unknown type `#{name}`"
    else
      "unknown type `#{name}` — an annotation names concrete types; `#{name}` in an answer means any type " <>
        "and cannot be written"
    end
  end

  # What the table says of `name`, the table built on the first unbound
  # name a check meets (unless handed in); nil when the check has no table.
  defp what_the_table_says(%Ctx{sigs: sigs} = ctx, name) when is_map(sigs) do
    table = ctx.table || table(sigs)
    {says(table, name), %{ctx | table: table}}
  end

  defp what_the_table_says(ctx, _name), do: {nil, ctx}

  # Three ways to find what the writer meant: the name itself; its owner,
  # which turns a guessed member (`Game.Board.new`) into the model it hangs
  # off; and a case-insensitive match of the whole name or, for an undotted
  # name, of any declaration's last segment.
  defp decl_for(%{sigs: sigs, names: index}, name) do
    dotted = String.contains?(name, ".")
    owner = Extract.owner_of(name)

    cond do
      Map.has_key?(sigs, name) ->
        {name, sigs[name]}

      dotted and Map.has_key?(sigs, owner) ->
        {owner, sigs[owner]}

      true ->
        case close(index, String.downcase(name), dotted) do
          nil -> nil
          found -> {found, sigs[found]}
        end
    end
  end

  # What does exist under `name`'s namespace: the first nine, sorted. Looked
  # up in the table's sorted names, never scanned out of it: a patch of many
  # unbound references stages in time linear in its size.
  defp siblings(%{sorted: sorted}, name) do
    if String.contains?(name, ".") do
      prefix = Extract.owner_of(name) <> "."

      take_prefixed(
        sorted,
        first_at_least(sorted, prefix, 0, tuple_size(sorted)),
        prefix,
        name,
        9
      )
    else
      []
    end
  end

  # The first index in `lo..hi` whose name is not below `key`.
  defp first_at_least(_sorted, _key, lo, hi) when lo >= hi, do: lo

  defp first_at_least(sorted, key, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(sorted, mid) < key,
      do: first_at_least(sorted, key, mid + 1, hi),
      else: first_at_least(sorted, key, lo, mid)
  end

  defp take_prefixed(_sorted, _i, _prefix, _name, 0), do: []

  defp take_prefixed(sorted, i, prefix, name, n) when i < tuple_size(sorted) do
    found = elem(sorted, i)

    cond do
      not String.starts_with?(found, prefix) -> []
      found == name -> take_prefixed(sorted, i + 1, prefix, name, n)
      true -> [found | take_prefixed(sorted, i + 1, prefix, name, n - 1)]
    end
  end

  defp take_prefixed(_sorted, _i, _prefix, _name, _n), do: []

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

  def misuse_hint(found, {:routes, _}),
    do:
      "`#{found}` is a route table — a deployment serves it; open one of its apps with `Cmd.navigate`"

  def misuse_hint(found, {:def, _, _, _}),
    do: "`#{found}` is what you want — every name is fully qualified, so write `#{found}`"
end
