defmodule Nobi.Lang.Types.Exhaustive do
  @moduledoc """
  Exhaustiveness of a `case` on a tuple (ported from
  `types/check/exhaustive.rs`): a pattern-matrix usefulness check after
  Maranget's "Warnings for pattern matching", asking only whether some value
  is matched by no arm, and naming one.

  Arms are first lowered against the scrutinee's type, so each column holds
  patterns of one type, whose constructors are a deftype's variants, `Bool`'s
  `true` and `false`, or a tuple's one. `Int`, `String` and `Uuid` have too
  many values to list: only a binder or `_` covers them.

  The search is co-NP-complete in general, so it is bounded once per
  declaration (`@base_work`, plus `@work_per_cell` for every cell of every
  case); past the bound the case is refused as too complex to check.

  A lowered pattern is `:any`, `{:lit, value}` (an `Int` or `String`
  literal), or `{:ctor, {kind, index}, args}` with `kind` one of `:bool`,
  `{:tuple, n}` or `{:deftype, at}`. A row is `{cells, refutable, width}`.
  """

  alias Nobi.Lang.Types.{Extract, Infer, Patterns, Quote}
  alias Nobi.Lang.Types.Check.Ctx

  @base_work 100_000
  @work_per_cell 64

  @doc "Holds a `case` on a tuple until `check_tuple_cases/1`, once the body is checked."
  def weigh_later(ctx, scrutinee, ty, arms) do
    case_ = %{quoted: Quote.expr(scrutinee), ty: ty, patterns: Enum.map(arms, &elem(&1, 0))}
    %{ctx | tuple_cases: [case_ | ctx.tuple_cases]}
  end

  @doc """
  Refuses each held `case` on a tuple when some value is matched by none of
  its arms, or when telling is too complex: all within one budget.
  """
  def check_tuple_cases(ctx) do
    cases = Enum.reverse(ctx.tuple_cases)
    ctx = %{ctx | tuple_cases: []}

    {ctx, _} =
      Enum.reduce_while(cases, {ctx, @base_work}, fn case_, {ctx, left} ->
        if Ctx.stopped?(ctx),
          do: {:halt, {ctx, left}},
          else: {:cont, refuse_missing(ctx, case_, left)}
      end)

    ctx
  end

  defp refuse_missing(ctx, case_, left) do
    {resolved, ctx} = Ctx.resolve_deep(ctx, case_.ty, fn -> case_.quoted end)

    if Infer.contains_uvar?(resolved) and not ctx.infer.lone_expression do
      {ctx, left}
    else
      weigh(ctx, case_, left)
    end
  end

  defp weigh(ctx, case_, left) do
    {lowered, {deftypes, ctx}} =
      Enum.map_reduce(case_.patterns, {new_deftypes(), ctx}, fn p, {d, ctx} ->
        {pat, d, ctx} = lower(ctx, p, case_.ty, d)
        {pat, {d, ctx}}
      end)

    # An arm that does not fit its type was reported when it was bound.
    if Enum.any?(lowered, &is_nil/1) and not Ctx.no_errors?(ctx) do
      {ctx, left}
    else
      pats = Enum.reject(lowered, &is_nil/1)
      cells = pats |> Enum.map(&size/1) |> Enum.sum()
      rows = Enum.map(pats, &{[&1], refutable([&1]), 1})
      left = left + cells * @work_per_cell
      shown = Ctx.format(ctx, case_.ty)

      {message, left} =
        try do
          {values, left} = missing(rows, 1, {deftypes, left})

          case values do
            nil ->
              {nil, left}

            [first | _] ->
              {"case on `#{shown}` is not exhaustive — missing: #{Quote.pattern(first)}", left}
          end
        catch
          {:too_complex, left} ->
            {"case on `#{shown}` is too complex to check that it is exhaustive — end it with a " <>
               "`_` or binder arm", left}
        end

      ctx = if message, do: Ctx.error(ctx, "non-exhaustive", message), else: ctx
      {ctx, left}
    end
  end

  # --- lowering -----------------------------------------------------------

  defp new_deftypes, do: %{index: %{}, all: %{}}

  defp deftype_index(d, owner, variants) do
    case d.index do
      %{^owner => at} ->
        {at, d}

      _ ->
        at = map_size(d.all)
        {at, %{index: Map.put(d.index, owner, at), all: Map.put(d.all, at, {owner, variants})}}
    end
  end

  # `p`, matched against `ty`, as the search sees it; nil when it does not
  # fit `ty` or `ty` is not known. Stops at the first item that does not
  # lower, as Rust's `collect::<Option<_>>()` does (so later items consult
  # no signature).
  defp lower(ctx, p, ty, d) do
    named? = fn want -> Ctx.shallow(ctx, ty) == {:named, want} end

    case p do
      :wild ->
        {:any, d, ctx}

      {:pvar, _} ->
        {:any, d, ctx}

      {:pint, n} ->
        {if(named?.("Int"), do: {:lit, {:int, n}}), d, ctx}

      {:pstr, s} ->
        {if(named?.("String"), do: {:lit, {:str, s}}), d, ctx}

      {:pbool, b} ->
        {if(named?.("Bool"), do: {:ctor, {:bool, if(b, do: 0, else: 1)}, []}), d, ctx}

      {:ptuple, items} ->
        case Ctx.shallow(ctx, ty) do
          {:tuple, types} when length(types) == length(items) ->
            {args, _, d, ctx} =
              lower_all(ctx, Enum.zip(items, types), d, nil, fn ctx, {item, t}, d, nil ->
                {pat, d, ctx} = lower(ctx, item, t, d)
                {pat, nil, d, ctx}
              end)

            {args && {:ctor, {{:tuple, length(types)}, 0}, args}, d, ctx}

          _ ->
            {nil, d, ctx}
        end

      {:pvariant, name, args} ->
        lower_variant(ctx, name, args, ty, d)
    end
  end

  defp lower_variant(ctx, name, args, ty, d) do
    {vtype, ctx} = Patterns.variant_type(ctx, ty)

    index =
      vtype && Enum.find_index(vtype.variants, fn {v, _} -> v == Extract.last_segment(name) end)

    with true <- index != nil,
         {_, arg_types} = Enum.at(vtype.variants, index),
         true <- Extract.owner_of(name) == vtype.owner and length(arg_types) == length(args) do
      {at, d} = deftype_index(d, vtype.owner, vtype.variants)

      {pats, _vtype, d, ctx} =
        lower_all(ctx, Enum.zip(arg_types, args), d, vtype, fn ctx, {arg, sub}, d, vtype ->
          {t, vtype, ctx} = Patterns.arg_type(ctx, vtype, arg)
          {pat, d, ctx} = lower(ctx, sub, t, d)
          {pat, vtype, d, ctx}
        end)

      {pats && {:ctor, {{:deftype, at}, index}, pats}, d, ctx}
    else
      _ -> {nil, d, ctx}
    end
  end

  # Lowers each of `items` with `each` (`ctx, item, d, extra -> {pat, extra,
  # d, ctx}`), threading `extra`, stopping at the first nil (Rust's
  # `collect::<Option<_>>()`). Returns `{pats | nil, extra, d, ctx}`.
  defp lower_all(ctx, items, d, extra, each) do
    Enum.reduce_while(items, {[], extra, d, ctx}, fn item, {acc, extra, d, ctx} ->
      case each.(ctx, item, d, extra) do
        {nil, extra, d, ctx} -> {:halt, {nil, extra, d, ctx}}
        {pat, extra, d, ctx} -> {:cont, {[pat | acc], extra, d, ctx}}
      end
    end)
    |> then(fn
      {nil, _, _, _} = none -> none
      {acc, extra, d, ctx} -> {Enum.reverse(acc), extra, d, ctx}
    end)
  end

  defp size({:ctor, _, args}), do: 1 + (args |> Enum.map(&size/1) |> Enum.sum())
  defp size(_), do: 1

  defp refutable(cells), do: Enum.count(cells, &(&1 != :any))

  # --- the search ---------------------------------------------------------
  #
  # `missing(rows, width, {deftypes, left})` is a value of `width` columns no
  # row matches, as one pattern per column (first column first, `:wild`
  # where any value would do), or nil when every value is matched; with the
  # steps left. Running out of steps throws `{:too_complex, left}`.

  defp missing([], width, {_, left}), do: {List.duplicate(:wild, width), left}

  defp missing(rows, width, {d, left} = s) do
    if Enum.any?(rows, fn {_, r, _} -> r == 0 end) do
      {nil, left}
    else
      heads = for {[{:ctor, ctor, _} | _], _, _} <- rows, do: ctor

      case heads do
        [] ->
          missing_after(unlisted(rows), rows, width, s)

        [{kind, _} | _] ->
          count = count(d, kind)
          left = charge(left, count)
          present = for {^kind, i} <- heads, into: MapSet.new(), do: i

          case Enum.find(0..(count - 1)//1, &(not MapSet.member?(present, &1))) do
            nil ->
              each_ctor(rows, width, kind, 0, count, {d, left})

            index ->
              ctor = {kind, index}
              head = pattern(d, ctor, List.duplicate(:wild, arity(d, ctor)))
              missing_after(head, rows, width, {d, left})
          end
      end
    end
  end

  defp each_ctor(_rows, _width, _kind, index, count, {_, left}) when index == count,
    do: {nil, left}

  defp each_ctor(rows, width, kind, index, count, {d, left}) do
    ctor = {kind, index}
    arity = arity(d, ctor)
    {matching, left} = specialize(rows, ctor, arity, left)

    case missing(matching, arity + width - 1, {d, left}) do
      {nil, left} ->
        each_ctor(rows, width, kind, index + 1, count, {d, left})

      {values, left} ->
        {args, rest} = Enum.split(values, arity)
        {[pattern(d, ctor, args) | rest], left}
    end
  end

  defp missing_after(head, rows, width, {d, left}) do
    {rest, left} = default(rows, left)

    case missing(rest, width - 1, {d, left}) do
      {nil, left} -> {nil, left}
      {values, left} -> {[head | values], left}
    end
  end

  # The rows whose first pattern matches what `ctor` builds, that pattern
  # replaced by its `arity` argument patterns (`:any`s for a binder or `_`).
  defp specialize(rows, ctor, arity, left) do
    {out, left} =
      Enum.reduce(rows, {[], left}, fn {cells, r, w}, {out, left} ->
        left = charge(left, 1)

        case cells do
          [{:ctor, ^ctor, args} | rest] ->
            width = arity + w - 1
            left = charge(left, width)
            {[{args ++ rest, r - 1 + refutable(args), width} | out], left}

          [:any | rest] ->
            width = arity + w - 1
            left = charge(left, width)
            {[{List.duplicate(:any, arity) ++ rest, r, width} | out], left}

          _ ->
            {out, left}
        end
      end)

    {Enum.reverse(out), left}
  end

  # The rows whose first pattern is a binder or `_`, without it.
  defp default(rows, left) do
    {out, left} =
      Enum.reduce(rows, {[], left}, fn
        {[:any | rest], r, w}, {out, left} -> {[{rest, r, w - 1} | out], charge(left, 1)}
        _, {out, left} -> {out, charge(left, 1)}
      end)

    {Enum.reverse(out), left}
  end

  defp charge(left, steps) when steps > left, do: throw({:too_complex, left})
  defp charge(left, steps), do: left - steps

  defp count(_d, :bool), do: 2
  defp count(_d, {:tuple, _}), do: 1
  defp count(d, {:deftype, at}), do: d.all |> Map.fetch!(at) |> elem(1) |> length()

  defp arity(_d, {:bool, _}), do: 0
  defp arity(_d, {{:tuple, n}, _}), do: n

  defp arity(d, {{:deftype, at}, index}) do
    {_, variants} = Map.fetch!(d.all, at)
    variants |> Enum.at(index) |> elem(1) |> length()
  end

  defp pattern(_d, {:bool, index}, _args), do: {:pbool, index == 0}
  defp pattern(_d, {{:tuple, _}, _}, args), do: {:ptuple, args}

  defp pattern(d, {{:deftype, at}, index}, args) do
    {owner, variants} = Map.fetch!(d.all, at)
    {v, _} = Enum.at(variants, index)
    {:pvariant, "#{owner}.#{v}", args}
  end

  # A value for a column no constructor stands for, that no row starts
  # with: the first `Int` from 0 up no row names, or the shortest `String`
  # of `a`s, when rows name some; `_` otherwise.
  defp unlisted(rows) do
    {ints, strs} =
      Enum.reduce(rows, {MapSet.new(), MapSet.new()}, fn
        {[{:lit, {:int, n}} | _], _, _}, {i, s} -> {MapSet.put(i, n), s}
        {[{:lit, {:str, x}} | _], _, _}, {i, s} -> {i, MapSet.put(s, x)}
        _, acc -> acc
      end)

    cond do
      MapSet.size(ints) > 0 ->
        {:pint, Enum.find(Stream.iterate(0, &(&1 + 1)), &(not MapSet.member?(ints, &1)))}

      MapSet.size(strs) > 0 ->
        n =
          Enum.find(
            Stream.iterate(0, &(&1 + 1)),
            &(not MapSet.member?(strs, String.duplicate("a", &1)))
          )

        {:pstr, String.duplicate("a", n)}

      true ->
        :wild
    end
  end
end
