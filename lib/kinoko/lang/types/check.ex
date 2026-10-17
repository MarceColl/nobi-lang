defmodule Kinoko.Lang.Types.Check do
  @moduledoc """
  The checker (ported from `types/check/mod.rs` and the entry points of
  `decl.rs`): synthesis for every expression form, the rules of each kind of
  declaration, and `finalize`, which resolves every node's inference type
  into the type the typed tree carries.

  Every check starts from a fresh `Kinoko.Lang.Types.Check.Ctx`, so one
  declaration's errors never reach another's. A check sees only signatures,
  never another declaration's body. `sigs` is a map `%{name => signature}`
  or a lookup function `(name -> signature | nil)`; every lookup goes
  through `Ctx.dget/2`, so `deps` is exactly the names the check consulted
  (absent ones included: declaring one later must check this again).

  A check returns `%{deps: MapSet.t(), result: {:ok, typed} | {:error, [%{code, message}]},
  looked_up: MapSet.t(), groups: MapSet.t(), unbound: [String.t() | nil]}`.
  `unbound` has one entry per error: the name an `"unbound"` error is about
  (whose message the whole table can reword, `Hints.reword/2`), else `nil`. `looked_up` is the names whose
  signatures the check read itself (each through `Ctx.dget/2`); `groups` is
  the deftypes whose map-key positions it consulted (`Kinoko.Lang.Types.Keys`),
  each standing for its whole group in `deps`. What a check gives follows
  from those signatures and those groups' settled positions alone, so a memo
  (the universe's) records a read of each and nothing else.
  The typed tree is the input with `type:` and `res:` added to each
  expression node's meta (`res` is `nil` where nothing resolved). A def's or
  test's body block carries its value's type too.

  Synthesis annotates each node with an inference type (uvars allowed);
  `finalize_node/2` resolves it. Pattern binding is
  `Kinoko.Lang.Types.Patterns`; a tuple `case`'s exhaustiveness is
  `Kinoko.Lang.Types.Exhaustive`; name rules are `Check.Decl`. JSX and
  `defapp` are `Kinoko.Lang.Types.JsxApp`, the map-key rule is
  `Kinoko.Lang.Types.Keys`, what an unbound name says is
  `Kinoko.Lang.Types.Hints`, and stored models, field defaults and the
  model each store form works on are `Kinoko.Lang.Types.Store`.
  """

  alias Kinoko.Lang.Ast

  alias Kinoko.Lang.Types.{
    Exhaustive,
    Extract,
    Hints,
    Infer,
    JsxApp,
    Keys,
    Patterns,
    Quote,
    Routes,
    Store
  }

  alias Kinoko.Lang.Types.Check.{Ctx, Decl}

  import Kinoko.Lang.Types.Check.Tree,
    only: [ty: 1, res: 1, put_ann: 3, map_children: 3, map_stmt: 3]

  @scalars ~w(Int String Bool Uuid)

  @type result :: %{
          deps: MapSet.t(String.t()),
          result: {:ok, term()} | {:error, [%{code: String.t(), message: String.t()}]},
          looked_up: MapSet.t(String.t()),
          groups: MapSet.t(String.t()),
          unbound: [String.t() | nil]
        }

  # ---------- entry points (bodies in Check.Decl, as decl.rs) ----------

  @doc """
  Checks `decl` against `sigs`, the signatures of everything it may use
  (TS's `checkDecl`): its own names first, then the rules of its kind.
  `table:` is `Kinoko.Lang.Types.Hints.table(sigs)`, for a caller checking
  many declarations against one map of signatures: built once, not once per
  check that meets an unbound name.
  """
  @spec decl(Ast.decl(), map() | (String.t() -> term()), keyword()) :: result()
  defdelegate decl(decl, sigs, opts \\ []), to: Decl, as: :check_decl

  @doc """
  Checks `expr` alone against `sigs` (the server's `eval`): a declaration
  body's synthesis and finalize, but it may stay polymorphic: a type left
  open is a type variable (`a`, `b`, …), never `cannot-infer`.
  """
  @spec expr(Ast.node_(), map() | (String.t() -> term())) :: result()
  defdelegate expr(expr, sigs), to: Decl, as: :check_expr

  @doc """
  Checks every declaration of a program (TS's `checkProgram`), each against
  `base` (the stdlib's signatures, as a rule) and every declaration's own
  signature, all extracted first. A later declaration of a name takes an
  earlier one's place. `base` may be a map or a lookup function. Returns
  `%{name => result}`.
  """
  @spec program([Ast.decl()], map() | (String.t() -> term())) :: %{String.t() => result()}
  defdelegate program(decls, base), to: Decl, as: :check_program

  # ---------- JSX, apps, map keys, hints (their own modules) ----------

  @doc "`defapp`'s shape (`Kinoko.Lang.Types.JsxApp.check_app/2`)."
  defdelegate check_app(ctx, name), to: JsxApp

  @doc "An element, an `Html<m>` (`Kinoko.Lang.Types.JsxApp.synth_jsx/2`)."
  defdelegate synth_jsx(ctx, e), to: JsxApp

  @doc """
  Reports `t` when a `Map` key in it is not data (`Kinoko.Lang.Types.Keys`):
  a function type, `Cmd` or `Html`, found directly (`Map<(Int -> Int), Int>`)
  or passed to a deftype parameter that reaches a key. Every annotation
  (`validate_annotation/3`) and every node's finalized type
  (`finalize_node/2`) come through here: the only two places a type enters
  a program. Each offending type is reported once per check, keyed on the
  type itself, never its (cut) quoted text.
  """
  def refuse_non_data_map_keys(ctx, t) do
    {data?, ctx} = Keys.keys_are_data(ctx, t)

    cond do
      data? ->
        ctx

      MapSet.member?(ctx.reported_non_data_maps, t) ->
        ctx

      true ->
        message =
          "the type `#{Quote.type(t)}` holds a `Map` whose key is not data — map keys cannot hold a " <>
            "function, `Cmd`, or `Html`"

        ctx = %{ctx | reported_non_data_maps: MapSet.put(ctx.reported_non_data_maps, t)}
        Ctx.error(ctx, "non-data-map-key", message)
    end
  end

  @doc "What `name`, which did not resolve, says (`Kinoko.Lang.Types.Hints.unbound_message/3`)."
  defdelegate unbound_message(ctx, name, as_value), to: Hints

  # ---------- annotations ----------

  @doc """
  Validates an annotation where it is written: every name resolves (a
  builtin, one of `type_params`, a declared model or type) with as many
  parameters as it declares, then the map-key rule over the type whole.
  """
  def validate_annotation(ctx, t, type_params) do
    ctx |> validate_type(t, type_params) |> refuse_non_data_map_keys(t)
  end

  defp validate_type(ctx, {:named, name}, tp) do
    cond do
      name in Extract.builtin_named() or MapSet.member?(tp, name) ->
        ctx

      name == "Html" ->
        Ctx.error(
          ctx,
          "arity",
          "type `Html` expects 1 parameter(s): the type of the messages it sends, as in `Html<App.Msg>`"
        )

      true ->
        case Ctx.dget(ctx, name) do
          {{:model, _}, ctx} ->
            ctx

          {{:type, [], _}, ctx} ->
            ctx

          {{:type, ps, _}, ctx} ->
            Ctx.error(ctx, "arity", "type `#{name}` expects #{length(ps)} parameter(s)")

          {_, ctx} ->
            Ctx.error(ctx, "unbound", Hints.unknown_type(name))
        end
    end
  end

  defp validate_type(ctx, {:applied, name, args}, tp) do
    {expected, ctx} =
      case Map.fetch(Extract.builtin_applied(), name) do
        {:ok, arity} ->
          {arity, ctx}

        :error ->
          case Ctx.dget(ctx, name) do
            {{:type, ps, _}, ctx} -> {length(ps), ctx}
            {_, ctx} -> {nil, ctx}
          end
      end

    ctx =
      cond do
        expected == nil ->
          Ctx.error(ctx, "unbound", Hints.unknown_type(name))

        expected != length(args) ->
          message = "type `#{name}` expects #{expected} parameter(s), got #{length(args)}"
          Ctx.error(ctx, "arity", message)

        true ->
          ctx
      end

    Enum.reduce(args, ctx, &validate_type(&2, &1, tp))
  end

  defp validate_type(ctx, {:arrow, ps, ret}, tp),
    do: ps |> Enum.reduce(ctx, &validate_type(&2, &1, tp)) |> validate_type(ret, tp)

  defp validate_type(ctx, {:tuple, items}, tp),
    do: Enum.reduce(items, ctx, &validate_type(&2, &1, tp))

  defp validate_type(ctx, {:var, _}, _tp), do: ctx

  # ---------- name resolution ----------

  # What `name` refers to, and its type (TS's `resolveName`): a local; else,
  # for a dotted name with a capitalised last segment, a variant of the type
  # its owner names; else a def. A variant is an arrow when called
  # (`for_call`), its type when it has no arguments, and otherwise a
  # constructor used as a value (`:ctor_ref`). Every signature is
  # instantiated fresh.
  defp resolve_name(ctx, name, for_call) do
    case Ctx.lookup_local(ctx, name) do
      nil ->
        cond do
          not String.contains?(name, ".") -> {nil, ctx}
          Extract.variant_name?(name) -> resolve_variant(ctx, name, for_call)
          true -> resolve_def(ctx, name)
        end

      local ->
        {{local, :local}, ctx}
    end
  end

  defp resolve_variant(ctx, name, for_call) do
    owner = Extract.owner_of(name)

    case Ctx.dget(ctx, owner) do
      {{:type, params, variants}, ctx} ->
        case List.keyfind(variants, Extract.last_segment(name), 0) do
          {variant, vargs} -> instantiate_variant(ctx, owner, params, variant, vargs, for_call)
          nil -> {nil, ctx}
        end

      {_, ctx} ->
        {nil, ctx}
    end
  end

  # The variant's arguments and the type's own parameters share one
  # mapping, so `Option.Some(1)` is an `Option<Int>`.
  defp instantiate_variant(ctx, owner, params, variant, vargs, for_call) do
    pset = MapSet.new(params)

    {args, {mapping, ctx}} =
      Enum.map_reduce(vargs, {%{}, ctx}, fn a, {mapping, ctx} ->
        {t, mapping, ctx} = Ctx.instantiate(ctx, a, pset, mapping)
        {t, {mapping, ctx}}
      end)

    {result_args, {_, ctx}} =
      Enum.map_reduce(params, {mapping, ctx}, fn p, {mapping, ctx} ->
        case mapping do
          %{^p => u} ->
            {u, {mapping, ctx}}

          _ ->
            {u, ctx} = Ctx.fresh(ctx)
            {u, {Map.put(mapping, p, u), ctx}}
        end
      end)

    result = Patterns.type_of(owner, params, result_args)
    arity = length(vargs)

    found =
      cond do
        for_call -> {{:arrow, args, result}, {:variant, owner, variant, arity}}
        arity == 0 -> {result, {:variant, owner, variant, arity}}
        true -> {{:arrow, args, result}, {:ctor_ref, owner, variant, arity}}
      end

    {found, ctx}
  end

  # A def's signature has no type parameters of its own: only the stdlib's
  # scheme variables are freshened.
  defp resolve_def(ctx, name) do
    case Ctx.dget(ctx, name) do
      {{:def, params, ret, _names}, ctx} ->
        none = MapSet.new()

        {ps, {mapping, ctx}} =
          Enum.map_reduce(params, {%{}, ctx}, fn p, {mapping, ctx} ->
            {t, mapping, ctx} = Ctx.instantiate(ctx, p, none, mapping)
            {t, {mapping, ctx}}
          end)

        {r, _, ctx} = Ctx.instantiate(ctx, ret, none, mapping)
        {{{:arrow, ps, r}, {:def, name}}, ctx}

      {_, ctx} ->
        {nil, ctx}
    end
  end

  # ---------- synthesis ----------

  @doc """
  `e`, every node annotated with its inference type (TS's `synth`), each
  type measured as it is built: too large a one stops the check, and a
  stopped check looks at nothing more. Each expression lets the check do
  that much more type work. Public for JSX checking (`Kinoko.Lang.Types.JsxApp`).
  """
  def synth(ctx, e) do
    if Ctx.stopped?(ctx) do
      unchecked(ctx, e)
    else
      ctx = %{ctx | infer: Infer.allow(ctx.infer, Infer.type_work_per_node())}
      {s, ctx} = synth_form(ctx, e)
      {_, ctx} = Ctx.fits(ctx, ty(s), e)
      {s, ctx}
    end
  end

  defp synth_form(ctx, {:int, _, _} = e), do: {put_ann(e, named("Int"), nil), ctx}
  defp synth_form(ctx, {:str, _, _} = e), do: {put_ann(e, named("String"), nil), ctx}
  defp synth_form(ctx, {:bool, _, _} = e), do: {put_ann(e, named("Bool"), nil), ctx}

  # `Tx.delete` is a special form (`Store.synth_tx_delete/2`), never a value.
  defp synth_form(ctx, {:name, _, ["Tx.delete"]} = e) do
    ctx
    |> Ctx.error("bad-tx-delete", "`Tx.delete` " <> Store.tx_delete_why())
    |> unchecked(e)
  end

  defp synth_form(ctx, {:name, _, [name]} = e) do
    case resolve_name(ctx, name, false) do
      {{t, res}, ctx} ->
        {put_ann(e, t, res), ctx}

      {nil, ctx} ->
        {message, ctx} = unbound_message(ctx, name, true)
        {u, ctx} = ctx |> Ctx.unbound(name, message) |> Ctx.fresh()
        {put_ann(e, u, nil), ctx}
    end
  end

  defp synth_form(ctx, {:list, m, items}) do
    {elem, ctx} = Ctx.fresh(ctx)

    {items, ctx} =
      Enum.map_reduce(items, ctx, fn item, ctx ->
        {s, ctx} = synth(ctx, item)
        {s, Ctx.unify!(ctx, ty(s), elem, item)}
      end)

    {put_ann({:list, m, items}, {:applied, "List", [elem]}, nil), ctx}
  end

  defp synth_form(ctx, {:map, m, entries}) do
    {key, ctx} = Ctx.fresh(ctx)
    {value, ctx} = Ctx.fresh(ctx)

    {entries, ctx} =
      Enum.map_reduce(entries, ctx, fn {k, v}, ctx ->
        {ks, ctx} = synth(ctx, k)
        {vs, ctx} = synth(ctx, v)
        ctx = ctx |> Ctx.unify!(ty(ks), key, k) |> Ctx.unify!(ty(vs), value, v)
        {{ks, vs}, ctx}
      end)

    {put_ann({:map, m, entries}, {:applied, "Map", [key, value]}, nil), ctx}
  end

  defp synth_form(ctx, {:tuple, m, items}) do
    {items, ctx} = Enum.map_reduce(items, ctx, &synth(&2, &1))
    {put_ann({:tuple, m, items}, {:tuple, Enum.map(items, &ty/1)}, nil), ctx}
  end

  defp synth_form(ctx, {:bin, m, [op, l, r]}) do
    {ls, ctx} = synth(ctx, l)
    {rs, ctx} = synth(ctx, r)

    ctx =
      case operand(op) do
        # Polymorphic, but both sides alike.
        nil -> Ctx.unify!(ctx, ty(rs), ty(ls), r)
        t -> ctx |> Ctx.unify!(ty(ls), named(t), l) |> Ctx.unify!(ty(rs), named(t), r)
      end

    result =
      cond do
        op in [:+, :-, :*, :/] -> "Int"
        op == :++ -> "String"
        true -> "Bool"
      end

    {put_ann({:bin, m, [op, ls, rs]}, named(result), nil), ctx}
  end

  defp synth_form(ctx, {kind, m, [x]}) when kind in [:not, :neg, :always, :sometimes] do
    {operand, result} =
      case kind do
        :not -> {"Bool", "Bool"}
        :neg -> {"Int", "Int"}
        _ -> {"Bool", "Unit"}
      end

    {s, ctx} = synth(ctx, x)
    ctx = Ctx.unify!(ctx, ty(s), named(operand), x)
    {put_ann({kind, m, [s]}, named(result), nil), ctx}
  end

  defp synth_form(ctx, {:call, _, _} = e), do: synth_call(ctx, e)
  defp synth_form(ctx, {:field, _, _} = e), do: synth_field(ctx, e)

  defp synth_form(ctx, {:construct, m, [model, fields]} = e) do
    case Ctx.dget(ctx, model) do
      {{:model, declared}, ctx} ->
        ctx =
          Enum.reduce(declared, ctx, fn {f, t, _}, ctx ->
            if identity?(f, t) or List.keymember?(fields, f, 0),
              do: ctx,
              else: Ctx.error(ctx, "missing-field", "`%#{model}{…}` is missing field `#{f}`")
          end)

        {fields, ctx} = field_values(ctx, model, declared, fields)
        {put_ann({:construct, m, [model, fields]}, named(model), nil), ctx}

      {_, ctx} ->
        ctx |> Ctx.error("not-a-model", "`#{model}` is not a model") |> unchecked(e)
    end
  end

  # A construction's fields, all optional, over a row of the model.
  defp synth_form(ctx, {:update, m, [model, base, fields]} = e) do
    case Ctx.dget(ctx, model) do
      {{:model, declared}, ctx} ->
        {b, ctx} = synth(ctx, base)
        ctx = Ctx.unify!(ctx, ty(b), named(model), base)
        {fields, ctx} = field_values(ctx, model, declared, fields)
        {put_ann({:update, m, [model, b, fields]}, named(model), nil), ctx}

      {_, ctx} ->
        ctx |> Ctx.error("not-a-model", "`#{model}` is not a model") |> unchecked(e)
    end
  end

  defp synth_form(ctx, {:if, m, [c, t, o]}) do
    {cs, ctx} = synth(ctx, c)
    ctx = Ctx.unify!(ctx, ty(cs), named("Bool"), c)
    {ts, ctx} = synth(ctx, t)
    {os, ctx} = synth(ctx, o)
    ctx = Ctx.unify!(ctx, ty(os), ty(ts), o)
    {put_ann({:if, m, [cs, ts, os]}, ty(ts), nil), ctx}
  end

  defp synth_form(ctx, {:fn, m, [params, body]}) do
    ctx =
      Enum.reduce(params, ctx, fn {n, t}, ctx ->
        ctx |> validate_annotation(t, MapSet.new()) |> Ctx.check_ident(n)
      end)

    ctx = Decl.refuse_repeated_params(ctx, params, "this fn")
    {lifted, ctx} = Enum.map_reduce(params, ctx, fn {_, t}, ctx -> Ctx.written(ctx, t) end)
    scope = params |> Enum.map(&elem(&1, 0)) |> Enum.zip(lifted) |> Map.new()
    {b, ctx} = ctx |> Ctx.push_scope(scope) |> synth(body)
    {put_ann({:fn, m, [params, b]}, {:arrow, lifted, ty(b)}, nil), Ctx.pop_scope(ctx)}
  end

  defp synth_form(ctx, {:block, _, _} = e) do
    {block, _ty, ctx} = synth_block(ctx, e)
    {block, ctx}
  end

  defp synth_form(ctx, {:case, _, _} = e), do: synth_case(ctx, e)
  defp synth_form(ctx, {:jsx, _, _} = e), do: synth_jsx(ctx, e)

  # The annotation is the node's type, whatever `x` turned out to be: a
  # mismatch is reported once, here. What `x` resolves to is the node's too.
  defp synth_form(ctx, {:annot, m, [x, t]}) do
    ctx = validate_annotation(ctx, t, MapSet.new())
    {s, ctx} = synth(ctx, x)
    {annotated, ctx} = Ctx.written(ctx, t)
    ctx = Ctx.unify!(ctx, ty(s), annotated, x)
    {put_ann({:annot, m, [s, t]}, annotated, res(s)), ctx}
  end

  defp operand(op) when op in [:+, :-, :*, :/, :<, :>, :<=, :>=], do: "Int"
  defp operand(:++), do: "String"
  defp operand(op) when op in [:and, :or], do: "Bool"
  defp operand(_), do: nil

  # `id : Uuid` is identity, not data: the store mints it, so a
  # construction never supplies it.
  defp identity?(field, t), do: field == "id" and t == {:named, "Uuid"}

  # `name(args)`: the target must resolve to something callable with as
  # many arguments as are given, each checked against its parameter.
  defp synth_call(ctx, {:call, _, ["Cmd.navigate", _]} = e), do: Routes.synth_navigate(ctx, e)
  defp synth_call(ctx, {:call, _, ["Html.href", _]} = e), do: Routes.synth_href(ctx, e)
  defp synth_call(ctx, {:call, _, ["Tx.delete", _]} = e), do: Store.synth_tx_delete(ctx, e)

  defp synth_call(ctx, {:call, m, [name, args]} = e) do
    case resolve_name(ctx, name, true) do
      {nil, ctx} ->
        {message, ctx} = unbound_message(ctx, name, false)
        ctx = Ctx.unbound(ctx, name, message)
        {args, ctx} = Enum.map_reduce(args, ctx, &synth(&2, &1))
        {u, ctx} = Ctx.fresh(ctx)
        {put_ann({:call, m, [name, args]}, u, nil), ctx}

      {{t, res}, ctx} ->
        case Ctx.resolve_deep(ctx, t, fn -> Quote.expr(e) end) do
          {{:arrow, params, ret}, ctx} when length(params) == length(args) ->
            {args, ctx} =
              args
              |> Enum.zip(params)
              |> Enum.map_reduce(ctx, fn {arg, param}, ctx ->
                {s, ctx} = synth(ctx, arg)
                {s, Ctx.unify!(ctx, ty(s), param, arg)}
              end)

            {put_ann({:call, m, [name, args]}, ret, res), ctx}

          {{:arrow, params, _}, ctx} ->
            message =
              "`#{name}` expects #{length(params)} argument(s), got #{length(args)} in `#{Quote.expr(e)}`"

            {call, ctx} = ctx |> Ctx.error("arity", message) |> unchecked(e)
            {put_ann(call, ty(call), res), ctx}

          {_, ctx} ->
            shown = Ctx.format(ctx, t)

            ctx
            |> Ctx.error("not-a-function", "`#{name}` is not callable (type #{shown})")
            |> unchecked(e)
        end
    end
  end

  # `obj.field`: `obj` must be a row of a model that has `field`.
  #
  # A row whose type is not known yet (a `Store.get` result before the
  # model is used anywhere) waits: the field's type is a fresh variable,
  # settled once the row's type is (`settle_pending/1`).
  defp synth_field(ctx, {:field, m, [obj, field]} = e) do
    {o, ctx} = synth(ctx, obj)
    {resolved, ctx} = Ctx.resolve_deep(ctx, ty(o), fn -> Quote.expr(obj) end)

    case resolved do
      {:uvar, _} ->
        {u, ctx} = Ctx.fresh(ctx)
        waiting = %{at: e, obj: obj, ty: ty(o), field: field, result: u}
        ctx = %{ctx | pending_fields: [waiting | ctx.pending_fields]}
        {put_ann({:field, m, [o, field]}, u, nil), ctx}

      _ ->
        {t, ctx} = field_type(ctx, e, resolved, field)
        {put_ann({:field, m, [o, field]}, t, nil), ctx}
    end
  end

  # The type of `field` of a row of type `resolved` (`e` the access).
  defp field_type(ctx, e, resolved, field) do
    {found, ctx} =
      case resolved do
        {:named, model} ->
          case Ctx.dget(ctx, model) do
            {{:model, fields}, ctx} ->
              case List.keyfind(fields, field, 0) do
                {_, t, _} ->
                  {{:ok, t}, ctx}

                nil ->
                  names = Enum.map_join(fields, ", ", &elem(&1, 0))
                  message = "model `#{model}` has no field `#{field}` (has: #{names})"
                  {{:error, "unknown-field", message}, ctx}
              end

            {_, ctx} ->
              {{:error, "not-a-model", "`#{model}` is not a model in `#{Quote.expr(e)}`"}, ctx}
          end

        other ->
          shown = Ctx.format(ctx, other)
          message = "field access `.#{field}` needs a model, got #{shown} in `#{Quote.expr(e)}`"
          {{:error, "not-a-model", message}, ctx}
      end

    case found do
      {:ok, t} -> {t, ctx}
      {:error, code, message} -> ctx |> Ctx.error(code, message) |> Ctx.fresh()
    end
  end

  @doc """
  The patterns (`Kinoko.Lang.Types.Patterns.check_pending/1`) and field
  accesses waiting for their type, checked until none settles any more;
  then, in a declaration, each access still waiting is an error naming the
  annotation that settles it.
  """
  def settle_pending(ctx) do
    waiting = length(ctx.pending) + length(ctx.pending_fields)
    ctx = ctx |> Patterns.check_pending() |> check_pending_fields()

    cond do
      length(ctx.pending) + length(ctx.pending_fields) < waiting -> settle_pending(ctx)
      ctx.infer.lone_expression -> ctx
      true -> unsettled_fields(ctx)
    end
  end

  defp check_pending_fields(ctx) do
    {unknown, known} =
      ctx.pending_fields
      |> Enum.reverse()
      |> Enum.split_with(&match?({:uvar, _}, Ctx.shallow(ctx, &1.ty)))

    ctx = %{ctx | pending_fields: Enum.reverse(unknown)}

    Enum.reduce(known, ctx, fn %{at: e, obj: obj, ty: t, field: field, result: u}, ctx ->
      {resolved, ctx} = Ctx.resolve_deep(ctx, t, fn -> Quote.expr(obj) end)
      {declared, ctx} = field_type(ctx, e, resolved, field)
      Ctx.unify!(ctx, u, declared, e)
    end)
  end

  defp unsettled_fields(ctx) do
    ctx.pending_fields
    |> Enum.reverse()
    |> Enum.reduce(%{ctx | pending_fields: []}, fn %{at: e, obj: obj, field: field}, ctx ->
      Ctx.error(
        ctx,
        "not-a-model",
        "field access `.#{field}` needs a model, and nothing settles which one `#{Quote.expr(obj)}` " <>
          "is in `#{Quote.expr(e)}` — annotate where it comes from, as in " <>
          "`(Store.get(s, id) : Option<App.Row>)` or `(JSON.parse(text) : Result<App.Row, String>)`"
      )
    end)
  end

  # Each field a construction or an update sets, checked against the type
  # `model` declares for it, and set once.
  defp field_values(ctx, model, declared, given) do
    {fields, {ctx, _}} =
      Enum.map_reduce(given, {ctx, MapSet.new()}, fn {name, value}, {ctx, set} ->
        {s, ctx} = synth(ctx, value)

        ctx =
          case List.keyfind(declared, name, 0) do
            {_, t, _} -> Ctx.unify!(ctx, ty(s), t, value)
            nil -> Ctx.error(ctx, "extra-field", "model `#{model}` has no field `#{name}`")
          end

        ctx =
          if MapSet.member?(set, name),
            do:
              Ctx.error(ctx, "extra-field", "`%#{model}{…}` sets field `#{name}` more than once"),
            else: ctx

        {{name, s}, {ctx, MapSet.put(set, name)}}
      end)

    {fields, ctx}
  end

  # A block's statements, in a scope of their own; its type is its last
  # expression's. Returns `{typed_block, type, ctx}`.
  @doc false
  def synth_block(ctx, {:block, m, [stmts, last]}) do
    ctx = Ctx.push_scope(ctx)
    {stmts, ctx} = Enum.map_reduce(stmts, ctx, &synth_stmt(&2, &1))
    {last, ctx} = synth(ctx, last)
    t = ty(last)
    {put_ann({:block, m, [stmts, last]}, t, nil), t, Ctx.pop_scope(ctx)}
  end

  defp synth_stmt(ctx, {:expr, x}) do
    {s, ctx} = synth(ctx, x)
    {{:expr, s}, ctx}
  end

  defp synth_stmt(ctx, {:bind, name, value}) do
    {s, ctx} = synth(ctx, value)

    # Codegen emits a `const` per binder: one binder per name per block.
    ctx =
      if Ctx.bound_here?(ctx, name),
        do: Ctx.error(ctx, "bad-name", "`#{name}` is already bound in this block"),
        else: ctx

    # Functions are second-class: inlined at the call site, never named.
    ctx =
      case Ctx.shallow(ctx, ty(s)) do
        {:arrow, _, _} ->
          message = "`#{name}` cannot be bound to a function — inline it at the call site"
          Ctx.error(ctx, "bad-name", message)

        _ ->
          ctx
      end

    {{:bind, name, s}, Ctx.bind_local(ctx, name, ty(s))}
  end

  # `case` (TS's `synthCase`): the scrutinee is a variant type, whose
  # variants the arms must cover; a scalar, covered only by a binder or `_`;
  # or a tuple, whose arms together must match every value (weighed once
  # the body is checked). Each arm's binders are in scope in its body alone,
  # and every body has the case's one type.
  defp synth_case(ctx, {:case, m, [scrutinee, arms]}) do
    {scrut, ctx} = synth(ctx, scrutinee)
    {scrut_ty, ctx} = Ctx.resolve_deep(ctx, ty(scrut), fn -> Quote.expr(scrutinee) end)
    {result, ctx} = Ctx.fresh(ctx)
    {vtype, ctx} = Patterns.variant_type(ctx, scrut_ty)
    scalar = vtype == nil and match?({:named, n} when n in @scalars, scrut_ty)
    tuple = match?({:tuple, _}, scrut_ty)

    ctx =
      if vtype == nil and not scalar and not tuple do
        shown = Ctx.format(ctx, scrut_ty)

        message =
          "case scrutinee must be a variant type, a scalar or a tuple, got #{shown} in `#{Quote.expr(scrutinee)}`"

        Ctx.error(ctx, "mismatch", message)
      else
        ctx
      end

    # The scrutinee, quoted, when no variant pattern can match it.
    variantless = if scalar or tuple, do: "`#{Quote.expr(scrutinee)}`"

    {typed_arms, {ctx, vtype, covers_all, covered}} =
      Enum.map_reduce(arms, {ctx, vtype, false, MapSet.new()}, fn {pattern, body},
                                                                  {ctx, vtype, all, covered} ->
        ctx =
          case pattern do
            {:pvariant, name, _} when variantless != nil ->
              Patterns.not_a_variant_type(ctx, name, variantless, scrut_ty)

            _ ->
              ctx
          end

        {covers, vtype, ctx} = Patterns.bind(Ctx.push_scope(ctx), pattern, ty(scrut), vtype)

        {all, covered} =
          case covers do
            :all -> {true, covered}
            {:variant, v} -> {all, MapSet.put(covered, v)}
            :nothing -> {all, covered}
          end

        ctx = Patterns.refuse_repeated_binders(ctx, pattern)
        {b, ctx} = synth(ctx, body)
        ctx = ctx |> Ctx.pop_scope() |> Ctx.unify!(ty(b), result, body)
        {{pattern, b}, {ctx, vtype, all, covered}}
      end)

    ctx =
      with %{owner: owner, variants: variants} <- vtype,
           false <- covers_all,
           [_ | _] = missing <-
             for({v, _} <- variants, not MapSet.member?(covered, v), do: "#{owner}.#{v}") do
        message = "case on `#{owner}` is not exhaustive — missing: #{Enum.join(missing, ", ")}"
        Ctx.error(ctx, "non-exhaustive", message)
      else
        _ -> ctx
      end

    ctx =
      if scalar and not covers_all,
        do: Ctx.error(ctx, "non-exhaustive", "case on a scalar needs a final `_` or binder arm"),
        else: ctx

    ctx = if tuple, do: Exhaustive.weigh_later(ctx, scrutinee, ty(scrut), arms), else: ctx
    {put_ann({:case, m, [scrut, typed_arms]}, result, nil), ctx}
  end

  @doc """
  `e` with nothing known about it: what is left unchecked once an error
  makes checking it pointless. It consults no signature and reports
  nothing; the check has already failed.
  """
  def unchecked(ctx, e) do
    {u, ctx} = Ctx.fresh(ctx)
    {e, ctx} = map_children(e, ctx, &unchecked(&2, &1))
    {put_ann(e, u, nil), ctx}
  end

  # ---------- finalize ----------

  # Resolves the type of every node of a declaration's body block, of type
  # `ty` (TS's `finalize`), once the patterns that waited for their type and
  # every `case` on a tuple have been checked. A body whose own type stays
  # open is quoted whole.
  @doc false
  def finalize_body(ctx, {:block, m, [stmts, last]} = block, ty) do
    ctx = ctx |> settle_pending() |> Exhaustive.check_tuple_cases()
    {resolved, ctx} = Ctx.resolve_deep(ctx, ty, fn -> Quote.expr(block) end)

    ctx =
      if Ctx.no_errors?(ctx) and Infer.contains_uvar?(resolved),
        do: cannot_infer(ctx, block),
        else: ctx

    {stmts, ctx} =
      Enum.map_reduce(stmts, ctx, &map_stmt(&1, &2, fn x, ctx -> finalize_node(ctx, x) end))

    {last, ctx} = finalize_node(ctx, last)
    {put_ann({:block, m, [stmts, last]}, ty(last), nil), ctx}
  end

  # `e`'s type and its children's, outermost first. In a declaration, if
  # nothing else failed, the first node whose type still holds an inference
  # variable is `cannot-infer`; in a lone expression each one left is a type
  # variable instead, named in the order first met.
  @doc false
  def finalize_node(ctx, e) do
    {t, ctx} = Ctx.resolve_deep(ctx, ty(e), fn -> Quote.expr(e) end)
    # A store form names its stored model (before `cannot-infer`, which it
    # words better for a read whose model nothing settles).
    {e, ctx} = Store.check_form(ctx, e, t)

    {stripped, ctx} =
      if ctx.infer.lone_expression do
        names =
          Enum.reduce(Infer.uvar_ids(t), ctx.open_names, fn id, names ->
            Map.put_new(names, id, variable_name(map_size(names)))
          end)

        {Infer.strip_uvars(t, &Map.fetch!(names, &1)), %{ctx | open_names: names}}
      else
        ctx =
          if Ctx.no_errors?(ctx) and Infer.contains_uvar?(t), do: cannot_infer(ctx, e), else: ctx

        {Infer.strip_uvars(t, &"?#{&1}"), ctx}
      end

    ctx = refuse_non_data_map_keys(ctx, stripped)
    res = res(e)
    {e, ctx} = map_children(e, ctx, &finalize_node(&2, &1))
    {put_ann(e, stripped, res), ctx}
  end

  defp cannot_infer(ctx, e),
    do: Ctx.error(ctx, "cannot-infer", "cannot infer the type of `#{Quote.expr(e)}`")

  # The `n`th type variable's name, from 0: `a` to `z`, then `a1` to `z1`, …
  defp variable_name(n) do
    letter = <<?a + rem(n, 26)>>

    case div(n, 26) do
      0 -> letter
      round -> letter <> Integer.to_string(round)
    end
  end

  defp named(n), do: {:named, n}
end
