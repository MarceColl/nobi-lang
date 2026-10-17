defmodule Nobi.Lang.Types.Patterns do
  @moduledoc """
  Case pattern binding and per-variant coverage (ported from
  `types/check/patterns.rs`): the deftype a pattern matches against
  (`variant_type/2`), what each pattern covers of it, and the nested variant
  patterns revisited once their type is known (`check_pending/1`). What a
  tuple `case`'s arms cover together is `Nobi.Lang.Types.Exhaustive`'s.

  A variant type is `%{owner, params :: MapSet, variants, subst}`; `subst`
  (what the type's own parameters stand for) is shared by every pattern on
  one scrutinee, so it is threaded back out of every function that uses it.

  What a pattern covers: `:all` (a binder, `_`, or a tuple of those),
  `{:variant, name}` (every value of one variant), or `:nothing`.
  """

  alias Nobi.Lang.Types.{Extract, Quote}
  alias Nobi.Lang.Types.Check.Ctx

  @scalars ~w(Int String Bool Uuid)

  @doc "The types a `case` may match by value (TS's `SCALAR_TYPES`)."
  def scalars, do: @scalars

  @doc "A deftype's type, instantiated at `args`: named when it has no parameters."
  def type_of(owner, [], _args), do: {:named, owner}
  def type_of(owner, _params, args), do: {:applied, owner, args}

  @doc """
  The deftype `ty` is, whose variants a pattern matched against it may name;
  `nil` for any other type. The lookup goes through `dget`, so the check
  depends on every named or applied type looked up, even `Int`.
  """
  def variant_type(ctx, ty) do
    {name, args} =
      case Ctx.shallow(ctx, ty) do
        {:named, n} -> {n, nil}
        {:applied, n, args} -> {n, args}
        _ -> {nil, nil}
      end

    if name == nil do
      {nil, ctx}
    else
      case Ctx.dget(ctx, name) do
        {{:type, params, variants}, ctx} ->
          {subst, ctx} = param_subst(ctx, params, args)
          {%{owner: name, params: MapSet.new(params), variants: variants, subst: subst}, ctx}

        {_, ctx} ->
          {nil, ctx}
      end
    end
  end

  # The type's own parameters stand for the scrutinee's arguments (a fresh
  # variable for any it lacks), each aliased so a variant naming one many
  # times copies it as one node. Unapplied, they are freshened as the
  # variants' arguments are instantiated.
  defp param_subst(ctx, _params, nil), do: {%{}, ctx}

  defp param_subst(ctx, params, args) do
    {pairs, {_, ctx}} =
      Enum.map_reduce(params, {args, ctx}, fn p, {args, ctx} ->
        case args do
          [a | rest] ->
            {u, ctx} = Ctx.alias_type(ctx, a)
            {{p, u}, {rest, ctx}}

          [] ->
            {u, ctx} = Ctx.fresh(ctx)
            {{p, u}, {[], ctx}}
        end
      end)

    {Map.new(pairs), ctx}
  end

  @doc "The type of a variant's argument, declared `arg`, in a value of `vtype`."
  def arg_type(ctx, vtype, arg) do
    {t, subst, ctx} = Ctx.instantiate(ctx, arg, vtype.params, vtype.subst)
    {t, %{vtype | subst: subst}, ctx}
  end

  @doc """
  Binds `p`'s binders, each at the type of what it matches, with `p` checked
  against `ty` (TS's `bindPattern`). `vtype` is the deftype `ty` is, when it
  is one. Returns `{covers, vtype, ctx}`.
  """
  def bind(ctx, :wild, _ty, vtype), do: {:all, vtype, ctx}
  def bind(ctx, {:pvar, name}, ty, vtype), do: {:all, vtype, Ctx.bind_local(ctx, name, ty)}

  def bind(ctx, {:pint, i}, ty, vtype),
    do: {:nothing, vtype, Ctx.unify!(ctx, {:named, "Int"}, ty, {:int, [], [i]})}

  def bind(ctx, {:pstr, s}, ty, vtype),
    do: {:nothing, vtype, Ctx.unify!(ctx, {:named, "String"}, ty, {:str, [], [s]})}

  def bind(ctx, {:pbool, b}, ty, vtype),
    do: {:nothing, vtype, Ctx.unify!(ctx, {:named, "Bool"}, ty, {:bool, [], [b]})}

  def bind(ctx, {:pvariant, name, args}, _ty, vtype), do: bind_variant(ctx, name, args, vtype)

  def bind(ctx, {:ptuple, items} = p, ty, vtype) do
    {covers, ctx} = bind_tuple(ctx, p, items, ty)
    {covers, vtype, ctx}
  end

  # A tuple pattern: `ty` is a tuple of as many items, each matched by its
  # pattern, a variant one as one nested in a variant's arguments is. It
  # covers `:all` when every item does; one that does not fit covers nothing.
  defp bind_tuple(ctx, p, items, ty) do
    {types, whole, ctx} =
      case tuple_items(ctx, p, length(items), ty) do
        {nil, ctx} ->
          {types, ctx} = Ctx.fresh_n(ctx, length(items))
          {types, false, ctx}

        {types, ctx} ->
          {types, true, ctx}
      end

    {whole, ctx} =
      items
      |> Enum.zip(types)
      |> Enum.with_index(1)
      |> Enum.reduce({whole, ctx}, fn
        {{{:pvariant, name, args}, t}, i}, {_whole, ctx} ->
          {false, bind_nested_variant(ctx, name, args, t, "item #{i} of a tuple pattern")}

        {{item, t}, _i}, {whole, ctx} ->
          {covers, _, ctx} = bind(ctx, item, t, nil)
          {whole and covers == :all, ctx}
      end)

    {if(whole, do: :all, else: :nothing), ctx}
  end

  # The types of the `n` items of tuple pattern `p`, matched against `ty`:
  # `ty`'s own, settling `ty` to a tuple when not yet known. Any other type
  # is a reported mismatch, and nil.
  defp tuple_items(ctx, p, n, ty) do
    case Ctx.shallow(ctx, ty) do
      {:tuple, types} when length(types) == n ->
        {types, ctx}

      {:uvar, _} ->
        {items, ctx} = Ctx.fresh_n(ctx, n)

        case Ctx.unify_quoting(ctx, {:tuple, items}, ty, fn -> Quote.pattern(p) end) do
          {true, ctx} -> {items, ctx}
          {false, ctx} -> {nil, ctx}
        end

      _ ->
        shown = Ctx.format(ctx, ty)

        message =
          "type mismatch: expected #{shown}, got a tuple of #{n} in `#{Quote.pattern(p)}`"

        {nil, Ctx.error(ctx, "mismatch", message)}
    end
  end

  # A variant pattern: one of `vtype`'s variants, with as many sub-patterns
  # as it has arguments, each bound at its argument's type. It covers its
  # variant only when every sub-pattern covers `:all`; a nested variant
  # pattern is checked against its own type's variants and covers nothing
  # of this case.
  defp bind_variant(ctx, _name, _args, nil), do: {:nothing, nil, ctx}

  defp bind_variant(ctx, name, args, vtype) do
    owner = Extract.owner_of(name)
    variant_name = Extract.last_segment(name)
    variant = Enum.find(vtype.variants, fn {v, _} -> v == variant_name end)

    cond do
      owner != vtype.owner ->
        message = "pattern `#{name}` does not belong to `#{vtype.owner}`"
        {:nothing, vtype, Ctx.error(ctx, "bad-pattern", message)}

      variant == nil ->
        message = "`#{owner}` has no variant `#{variant_name}`"
        {:nothing, vtype, Ctx.error(ctx, "bad-pattern", message)}

      length(elem(variant, 1)) != length(args) ->
        message =
          "pattern `#{name}` expects #{length(elem(variant, 1))} argument(s), got #{length(args)}"

        {:nothing, vtype, Ctx.error(ctx, "bad-pattern", message)}

      true ->
        {v, arg_types} = variant

        {whole, vtype, ctx} =
          arg_types
          |> Enum.zip(args)
          |> Enum.with_index(1)
          |> Enum.reduce({true, vtype, ctx}, fn {{arg_ty, sub}, i}, {whole, vtype, ctx} ->
            {t, vtype, ctx} = arg_type(ctx, vtype, arg_ty)

            case sub do
              {:pvariant, sub_name, sub_args} ->
                at = "argument #{i} of `#{name}`"
                {false, vtype, bind_nested_variant(ctx, sub_name, sub_args, t, at)}

              _ ->
                {covers, _, ctx} = bind(ctx, sub, t, nil)
                {whole and covers == :all, vtype, ctx}
            end
          end)

        {if(whole, do: {:variant, v}, else: :nothing), vtype, ctx}
    end
  end

  # Variant pattern `name(args)`, nested `at`, of type `ty`: checked against
  # its own type's variants, refused when that is no variant type, or held
  # in `pending` while `ty` is not yet known.
  defp bind_nested_variant(ctx, name, args, ty, at) do
    case Ctx.shallow(ctx, ty) do
      {:uvar, _} ->
        pending = %{name: name, args: args, ty: ty, at: at}
        %{ctx | pending: [pending | ctx.pending]}

      _ ->
        quote = fn -> Quote.pattern({:pvariant, name, args}) end

        case Ctx.fits_quoting(ctx, ty, quote) do
          {false, ctx} ->
            ctx

          {true, ctx} ->
            {nested, ctx} = variant_type(ctx, ty)
            ctx = if nested == nil, do: not_a_variant_type(ctx, name, at, ty), else: ctx
            {_, _, ctx} = bind_variant(ctx, name, args, nested)
            ctx
        end
    end
  end

  @doc """
  Variant pattern `name` matched against `what`, of type `ty`, which is no
  variant type: the arm could never match. A `bad-pattern`.
  """
  def not_a_variant_type(ctx, name, what, ty) do
    {resolved, ctx} = Ctx.resolve_deep(ctx, ty, fn -> Quote.cut(name) end)

    instead =
      case resolved do
        {:named, n} when n in @scalars -> "a literal, `_` or a binder"
        {:tuple, _} -> "a tuple pattern, `_` or a binder"
        _ -> "`_` or a binder"
      end

    shown = Ctx.format(ctx, resolved)

    message =
      "pattern `#{name}` cannot match #{what}, of type #{shown}: only a deftype's values have variants — " <>
        "match it with #{instead}"

    Ctx.error(ctx, "bad-pattern", message)
  end

  @doc """
  Checks every nested variant pattern that waited for its type, now that the
  whole expression has been checked, each in a scope of its own. Repeats
  until a round checks none. In a lone expression, patterns whose type is
  still unknown are then checked by their own name (`settle_by_name`).
  """
  def check_pending(ctx) do
    if Ctx.stopped?(ctx) do
      ctx
    else
      waiting = Enum.reverse(ctx.pending)
      {unknown, known} = Enum.split_with(waiting, &match?({:uvar, _}, Ctx.shallow(ctx, &1.ty)))
      ctx = %{ctx | pending: Enum.reverse(unknown)}

      cond do
        known != [] ->
          known
          |> Enum.reduce(ctx, &recheck(&2, &1))
          |> check_pending()

        ctx.infer.lone_expression and ctx.pending != [] ->
          ctx |> settle_by_name() |> check_pending()

        true ->
          ctx
      end
    end
  end

  defp recheck(ctx, %{name: name, args: args, ty: ty, at: at}) do
    ctx
    |> Ctx.push_scope()
    |> bind_nested_variant(name, args, ty, at)
    |> Ctx.pop_scope()
  end

  # Every pattern still waiting in a lone expression, checked by its own
  # name in the order written: a variant of a deftype settles its type to
  # that deftype, fresh in its parameters.
  defp settle_by_name(ctx) do
    waiting = Enum.reverse(ctx.pending)

    Enum.reduce_while(waiting, %{ctx | pending: []}, fn %{name: name, args: args, ty: ty} = p,
                                                        ctx ->
      if Ctx.stopped?(ctx) do
        {:halt, ctx}
      else
        case settle(ctx, name, args, ty) do
          {:skip, ctx} -> {:cont, ctx}
          {:ok, ctx} -> {:cont, recheck(ctx, p)}
        end
      end
    end)
  end

  defp settle(ctx, name, args, ty) do
    case Ctx.shallow(ctx, ty) do
      {:uvar, _} ->
        owner = Extract.owner_of(name)

        case Ctx.dget(ctx, owner) do
          {{:type, params, _}, ctx} ->
            {fresh, ctx} = Ctx.fresh_n(ctx, length(params))
            quote = fn -> Quote.pattern({:pvariant, name, args}) end
            {_, ctx} = Ctx.unify_quoting(ctx, type_of(owner, params, fresh), ty, quote)
            {:ok, ctx}

          {nil, ctx} ->
            message = "unknown type `#{owner}` in pattern `#{name}`"
            {:skip, Ctx.error(ctx, "unbound", message)}

          {_, ctx} ->
            message = "`#{owner}` has no variant `#{Extract.last_segment(name)}`"
            {:skip, Ctx.error(ctx, "bad-pattern", message)}
        end

      _ ->
        {:ok, ctx}
    end
  end

  @doc "One binder per name per pattern, at any depth."
  def refuse_repeated_binders(ctx, pattern) do
    names = pattern |> binders([]) |> Enum.reverse()
    Ctx.refuse_repeated(ctx, names, &"`#{&1}` is already bound in this pattern")
  end

  defp binders({:pvar, n}, acc), do: [n | acc]
  defp binders({:pvariant, _, args}, acc), do: Enum.reduce(args, acc, &binders/2)
  defp binders({:ptuple, items}, acc), do: Enum.reduce(items, acc, &binders/2)
  defp binders(_, acc), do: acc
end
