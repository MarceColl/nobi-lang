defmodule Kinoko.Lang.Types.Check.Decl do
  @moduledoc """
  Declaration entry points and the rules that apply to a declaration's own
  names and stored data (ported from `types/check/decl.rs`). The public
  entry points are `Kinoko.Lang.Types.Check.decl/2`, `expr/2` and
  `program/2`, which delegate here.
  """

  alias Kinoko.Lang.Ast
  alias Kinoko.Lang.Types.{Check, Exhaustive, Extract, Infer, Patterns, Quote, Stdlib}
  alias Kinoko.Lang.Types.Check.Ctx

  # ---------- entry points (`Kinoko.Lang.Types.Check` delegates here) ----------

  @doc false
  def check_decl(decl, sigs) do
    ctx = check_name_convention(Ctx.new(sigs), decl)
    {typed, ctx} = check_kind(ctx, decl)
    finish(ctx, typed)
  end

  @doc false
  def check_expr(expr, sigs) do
    ctx = Ctx.new(sigs)
    ctx = %{ctx | infer: Infer.lone_expression(ctx.infer)}
    {synthed, ctx} = Check.synth(ctx, expr)
    ctx = ctx |> Patterns.check_pending() |> Exhaustive.check_tuple_cases()
    {typed, ctx} = Check.finalize_node(ctx, synthed)
    finish(ctx, typed)
  end

  @doc false
  def check_program(decls, base) do
    own = Map.new(decls, &{Ast.name(&1), Extract.signature(&1)})

    sigs =
      if is_map(base) do
        Map.merge(base, own)
      else
        fn name ->
          case own do
            %{^name => sig} -> sig
            _ -> base.(name)
          end
        end
      end

    Map.new(decls, &{Ast.name(&1), check_decl(&1, sigs)})
  end

  defp finish(ctx, typed) do
    result = if Ctx.no_errors?(ctx), do: {:ok, typed}, else: {:error, Ctx.errors(ctx)}
    %{deps: ctx.used, result: result}
  end

  defp check_kind(ctx, {:def, m, [name, params, ret, {:block, _, [_, last]} = body]}) do
    none = MapSet.new()
    ctx = Enum.reduce(params, ctx, fn {_, t}, ctx -> Check.validate_annotation(ctx, t, none) end)
    ctx = Check.validate_annotation(ctx, ret, none)
    # Not `bind_local`: the name rules checked each parameter already.
    {scope, ctx} =
      Enum.map_reduce(params, ctx, fn {p, t}, ctx ->
        {w, ctx} = Ctx.written(ctx, t)
        {{p, w}, ctx}
      end)

    ctx = Ctx.push_scope(ctx, Map.new(scope))
    {synthed, ty, ctx} = Check.synth_block(ctx, body)
    # Before finalize, which checks the patterns that waited for their
    # type: the return type can settle it. A mismatch blames the value.
    {ret_ty, ctx} = Ctx.written(ctx, ret)
    ctx = ctx |> Ctx.unify!(ty, ret_ty, last) |> Ctx.pop_scope()
    {body, ctx} = Check.finalize_body(ctx, synthed, ty)
    {{:def, m, [name, params, ret, body]}, ctx}
  end

  defp check_kind(ctx, {:defmodel, _, [_, fields]} = d) do
    ctx =
      Enum.reduce(fields, ctx, fn {f, t}, ctx ->
        ctx |> Check.validate_annotation(t, MapSet.new()) |> forbid_in_model_field(t, f)
      end)

    {d, ctx}
  end

  defp check_kind(ctx, {:deftype, _, [_, params, variants]} = d) do
    type_params = MapSet.new(params)

    ctx =
      for {v, args} <- variants, a <- args, reduce: ctx do
        ctx -> ctx |> Check.validate_annotation(a, type_params) |> forbid_in_model_field(a, v)
      end

    {d, ctx}
  end

  defp check_kind(ctx, {:defapp, _, [name]} = d), do: {d, Check.check_app(ctx, name)}

  # A test's body is checked as a def's with no parameters, its value
  # unconstrained.
  defp check_kind(ctx, {:deftest, m, [name, body]}) do
    {synthed, ty, ctx} = ctx |> Ctx.push_scope() |> Check.synth_block(body)
    {body, ctx} = Check.finalize_body(Ctx.pop_scope(ctx), synthed, ty)
    {{:deftest, m, [name, body]}, ctx}
  end

  @doc """
  Whether `t` is itself disallowed where data is required: a function type,
  `Cmd`, or `Html`. The predicate `forbid_in_model_field/3` and the map-key
  rule (`Kinoko.Lang.Types.Keys`) are built on.
  """
  def non_data?({:arrow, _, _}), do: true
  def non_data?({:named, n}), do: n == "Cmd"
  def non_data?({:applied, n, _}), do: n in ["Cmd", "Html"]
  def non_data?(_), do: false

  @doc """
  What a model field (or a deftype variant argument) may hold: data. Every
  function or effect in `t`, at any depth but inside a function, is an
  `invalid-model-field`.
  """
  def forbid_in_model_field(ctx, t, field) do
    ctx =
      if non_data?(t) do
        Ctx.error(ctx, "invalid-model-field", non_data_message(t, field))
      else
        ctx
      end

    case t do
      {:applied, _, args} -> Enum.reduce(args, ctx, &forbid_in_model_field(&2, &1, field))
      {:tuple, items} -> Enum.reduce(items, ctx, &forbid_in_model_field(&2, &1, field))
      _ -> ctx
    end
  end

  defp non_data_message({:arrow, _, _} = t, field),
    do:
      "model field `#{field}` cannot hold a function type `#{Quote.type(t)}` — models must persist"

  defp non_data_message({:named, n}, field), do: "model field `#{field}` cannot hold `#{n}`"

  defp non_data_message({:applied, n, _} = t, field) do
    what = if n == "Html", do: "a view is", else: "effects are"
    "model field `#{field}` cannot hold `#{Quote.type(t)}` — #{what} not data to store"
  end

  @stdlib_roots Stdlib.names() |> Enum.map(&hd(String.split(&1, "."))) |> Enum.uniq()

  # A namespace the compiler owns: a builtin type's, or the first segment of
  # a stdlib name.
  defp reserved_root?(root) do
    root in Extract.builtin_named() or Map.has_key?(Extract.builtin_applied(), root) or
      root in @stdlib_roots
  end

  @doc """
  A declaration's own names (TS's `checkNameConvention`): never in a
  reserved namespace; qualified by a module (an app's names its module);
  defs and tests end lowercase, models, types and apps capitalised; variants
  capitalised; every segment, parameter, field and variant a valid
  identifier; and none of them named twice.
  """
  def check_name_convention(ctx, {kind, _, args} = decl) do
    name = Ast.name(decl)
    last = Extract.last_segment(name)
    root = name |> String.split(".") |> hd()

    ctx =
      ctx
      |> when_true(
        reserved_root?(root),
        "`#{name}` is in the reserved `#{root}` namespace — pick another name"
      )
      |> when_true(
        not String.contains?(name, ".") and kind != :defapp,
        "`#{name}` has no module — every name is qualified: name it `Mod.#{name}`"
      )
      |> case_convention(kind, name, last)

    ctx =
      case decl do
        {:deftype, _, [_, _, variants]} ->
          variants
          |> Enum.reject(fn {v, _} -> Ast.capitalised?(v) end)
          |> Enum.reduce(ctx, fn {v, _}, ctx ->
            Ctx.error(ctx, "bad-name", "variant `#{v}` must be capitalized")
          end)

        _ ->
          ctx
      end

    ctx = name |> String.split(".") |> Enum.reduce(ctx, &Ctx.check_ident(&2, &1))

    ctx =
      case {kind, args} do
        {:def, [_, params, _, _]} ->
          Enum.reduce(params, ctx, &Ctx.check_ident(&2, elem(&1, 0)))

        {:defmodel, [_, fields]} ->
          Enum.reduce(fields, ctx, &Ctx.check_ident(&2, elem(&1, 0)))

        {:deftype, [_, _, variants]} ->
          Enum.reduce(variants, ctx, &Ctx.check_ident(&2, elem(&1, 0)))

        _ ->
          ctx
      end

    case {kind, args} do
      {:def, [_, params, _, _]} ->
        refuse_repeated_params(ctx, params, "`#{name}`")

      {:defmodel, [_, fields]} ->
        Ctx.refuse_repeated(
          ctx,
          Enum.map(fields, &elem(&1, 0)),
          &"`#{&1}` is already a field of `#{name}`"
        )

      {:deftype, [_, params, variants]} ->
        ctx
        |> Ctx.refuse_repeated(params, &"`#{&1}` is already a parameter of `#{name}`")
        |> Ctx.refuse_repeated(
          Enum.map(variants, &elem(&1, 0)),
          &"`#{&1}` is already a variant of `#{name}`"
        )

      _ ->
        ctx
    end
  end

  defp case_convention(ctx, kind, name, last) when kind in [:def, :deftest] do
    word = if kind == :def, do: "def", else: "deftest"

    when_true(
      ctx,
      Ast.capitalised?(last),
      "#{word} `#{name}` must end in a lowercase segment (capitalized names are types; variants are " <>
        "Type.Variant)"
    )
  end

  defp case_convention(ctx, _kind, name, last),
    do: when_true(ctx, not Ast.capitalised?(last), "`#{name}` must end in a capitalized segment")

  defp when_true(ctx, true, message), do: Ctx.error(ctx, "bad-name", message)
  defp when_true(ctx, false, _message), do: ctx

  @doc "A def's or a fn's parameters, each named once (`of` says whose)."
  def refuse_repeated_params(ctx, params, of) do
    Ctx.refuse_repeated(
      ctx,
      Enum.map(params, &elem(&1, 0)),
      &"`#{&1}` is already a parameter of #{of}"
    )
  end
end
