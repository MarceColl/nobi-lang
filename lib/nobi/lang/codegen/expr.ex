defmodule Nobi.Lang.Codegen.Expr do
  @moduledoc """
  A checked Nobi expression to Erlang abstract forms (ported in behaviour
  from kinoko-next `interp/eval.rs`). Pure.

  Every name arrives resolved (`meta[:res]`), so lowering matches on the
  resolution and never reads a name's spelling to decide what it is. No
  atom is made from user text: locals become positional variables (`V0`,
  `V1`, … fresh for every binding, so a rebinding is a new variable and
  no Erlang pattern ever matches against an earlier binding), defs become
  the positional function atoms of the name table, and every Nobi name
  that reaches a value stays a binary.

  ## Order of evaluation

  Erlang leaves the order of a call's arguments (and a tuple's, list's or
  map's elements) unspecified; Nobi evaluates left to right, which decides
  which runtime error a program throws and the order failed `always`s are
  recorded in. So every compound whose parts may do something (anything but
  a variable, a literal or a `fun`) binds those parts, in order, to fresh
  variables first (`seq/2`).

  ## Shapes

  Values follow `Nobi.Lang.Rt`'s table. `always(e)` is
  `case E of true -> {}; _ -> 'Elixir.Nobi.Exec.Hooks':always_failed(Src) end`
  (Rust records a false `always` and goes on). Inside a declaration,
  `sometimes(e)` is
  `case E of true -> 'Elixir.Nobi.Exec.Hooks':sometimes_held(Decl, Src); _ -> {} end`,
  so a deftest can be scored for the `sometimes` it never reached; in an
  expression evaluated against an image (no declaration) it evaluates `e`
  and is `{}`. `Src` is `Nobi.Lang.Format.expr/1` of `e`, the site's source
  as Rust's `Site` words it. A `case` ends in `_ -> Rt:no_arm!()`.

  A store form (`Nobi.Lang.Types.Store.forms/0`, and `Tx.delete`) is
  built with the model its node's `store:` meta names, called or applied
  as a value (a closure): a `Cmd.store.*` effect, a `{:tx, op, model, …}`
  op, or a call of `'Elixir.Nobi.Data.Hooks':store_get(S, Model, Id)` /
  `store_list(S, Model)`, the reads a running transaction answers.
  """

  alias Nobi.Lang.Format
  alias Nobi.Lang.Rt.Stdlib

  @a 1
  @rt Nobi.Lang.Rt
  @json Nobi.Lang.Rt.Json
  @hooks Nobi.Exec.Hooks
  @data_hooks Nobi.Data.Hooks
  @max_vars 10_000

  # The forms that work on one stored model (`Nobi.Lang.Types.Store`), by
  # arity: compiled with the model the checker settled (`store_form/3`).
  @store_forms for {name, {:def, params, _, _}} <- Nobi.Lang.Types.Stdlib.signatures(),
                   name in Nobi.Lang.Types.Store.forms(),
                   into: %{},
                   do: {name, length(params)}

  @typedoc """
  `n` is the next variable's number, `env` each local's variable, `names`
  the image's defs (`name => {fun_atom, arity}`), `module` the image module,
  `local?` whether the code is inside it (local calls) or outside it
  (`:erl_eval`, remote calls), and `decl` the declaration being lowered
  (`nil` for an expression evaluated against the image): what a `sometimes`
  that holds is recorded under.
  """
  @type ctx :: %{
          n: non_neg_integer(),
          env: %{String.t() => atom()},
          names: %{String.t() => {atom(), non_neg_integer()}},
          module: atom(),
          local?: boolean(),
          decl: String.t() | nil
        }

  @doc "A fresh context, lowering the declaration `decl` (`nil`: an expression)."
  @spec ctx(map(), atom(), boolean(), String.t() | nil) :: ctx
  def ctx(names, module, local?, decl \\ nil),
    do: %{n: 0, env: %{}, names: names, module: module, local?: local?, decl: decl}

  @doc "`params` (`[{name, type}]`) as fresh variables: their forms and the context binding them."
  @spec params(ctx, [{String.t(), term()}]) :: {[tuple()], ctx}
  def params(ctx, params) do
    Enum.map_reduce(params, ctx, fn {name, _type}, ctx -> bind(ctx, name) end)
  end

  @doc """
  A body: the forms of a block's statements, in order, then its last
  expression's (a non-block is one form). Bindings stay in scope for what
  follows and leave with the body.
  """
  @spec body(Nobi.Lang.Ast.node_(), ctx) :: {[tuple()], ctx}
  def body({:block, _, [stmts, last]}, ctx) do
    {forms, inner} = Enum.map_reduce(stmts, ctx, &stmt/2)
    {last, inner} = expr(last, inner)
    {forms ++ [last], scoped(ctx, inner)}
  end

  def body(e, ctx), do: expr(e, ctx) |> then(fn {f, ctx} -> {[f], ctx} end)

  defp stmt({:bind, name, e}, ctx) do
    {f, ctx} = expr(e, ctx)
    {v, ctx} = bind(ctx, name)
    {{:match, @a, v, f}, ctx}
  end

  defp stmt({:expr, e}, ctx), do: expr(e, ctx)

  # `inner`'s variable count, `outer`'s scope.
  defp scoped(outer, inner), do: %{outer | n: inner.n}

  defp bind(ctx, name) do
    v = next_var!(ctx)
    {{:var, @a, v}, %{ctx | n: ctx.n + 1, env: Map.put(ctx.env, name, v)}}
  end

  defp fresh(ctx) do
    v = next_var!(ctx)
    {{:var, @a, v}, %{ctx | n: ctx.n + 1}}
  end

  # The variable numbered `ctx.n`, refused past the cap before its atom is
  # made: every function names its variables `V0`, `V1`, … afresh, so no
  # program, however large, adds atoms beyond `V0`..`V#{@max_vars - 1}`.
  defp next_var!(%{n: n} = ctx) when n >= @max_vars do
    where = if ctx.decl, do: "`#{ctx.decl}`", else: "the expression"

    throw(
      {:codegen_limit,
       "#{where} needs more than #{@max_vars} Erlang variables (the limit per " <>
         "compiled function); split it into smaller defs"}
    )
  end

  defp next_var!(%{n: n}), do: :"V#{n}"

  @doc """
  The most Erlang variables one compiled function may use. Lowering past
  it throws `{:codegen_limit, message}`, which `Nobi.Lang.Codegen`
  answers as a `"compile"` error.
  """
  @spec max_vars() :: pos_integer()
  def max_vars, do: @max_vars

  # ---------- expressions ----------

  @doc "The form of one expression."
  @spec expr(Nobi.Lang.Ast.node_(), ctx) :: {tuple(), ctx}
  def expr({:int, _, [n]}, ctx), do: {lit(n), ctx}
  def expr({:str, _, [s]}, ctx), do: {lit(s), ctx}
  def expr({:bool, _, [b]}, ctx), do: {lit(b), ctx}

  def expr({:name, m, [name]}, ctx) do
    case m[:res] do
      {:def, def} when is_map_key(@store_forms, def) -> store_value(def, m[:store], ctx)
      res -> name(res, name, ctx)
    end
  end

  def expr({:list, _, items}, ctx) do
    seq(Enum.map(items, &{:e, &1}), ctx, fn fs ->
      List.foldr(fs, {nil, @a}, fn f, acc -> {:cons, @a, f, acc} end)
    end)
  end

  def expr({:map, _, []}, ctx), do: {{:map, @a, []}, ctx}

  def expr({:map, _, entries}, ctx) do
    parts = Enum.flat_map(entries, fn {k, v} -> [{:e, k}, {:e, v}] end)

    # A later key replaces an earlier one, as Rust's insertions do; each
    # key is charged by its weight before it is hashed (`Rt.map_from_list/1`).
    seq(parts, ctx, fn fs ->
      pairs = fs |> Enum.chunk_every(2) |> Enum.map(fn [k, v] -> {:tuple, @a, [k, v]} end)
      rt(:map_from_list, [List.foldr(pairs, {nil, @a}, &{:cons, @a, &1, &2})])
    end)
  end

  def expr({:tuple, _, items}, ctx),
    do: seq(Enum.map(items, &{:e, &1}), ctx, &{:tuple, @a, &1})

  def expr({:bin, _, [op, l, r]}, ctx) when op in [:and, :or] do
    {lf, ctx} = expr(l, ctx)
    {rf, ctx} = expr(r, ctx)
    {{:op, @a, if(op == :and, do: :andalso, else: :orelse), lf, rf}, ctx}
  end

  def expr({:bin, _, [op, l, r]}, ctx) do
    seq([{:e, l}, {:e, r}], ctx, fn [lf, rf] -> binary(op, lf, rf) end)
  end

  def expr({:not, _, [x]}, ctx) do
    {f, ctx} = expr(x, ctx)
    {{:op, @a, :not, f}, ctx}
  end

  def expr({:neg, _, [x]}, ctx) do
    {f, ctx} = expr(x, ctx)
    {rt(:neg, [f]), ctx}
  end

  def expr({:call, m, [name, args]}, ctx), do: call(m, name, args, ctx)

  def expr({:field, _, [x, field]}, ctx) do
    {f, ctx} = expr(x, ctx)
    {rt(:field, [f, lit(field)]), ctx}
  end

  def expr({:construct, _, [model, fields]}, ctx) do
    seq(Enum.map(fields, fn {_, x} -> {:e, x} end), ctx, fn fs ->
      {:tuple, @a, [lit(:rec), lit(model), field_map(fields, fs)]}
    end)
  end

  def expr({:update, _, [_model, base, fields]}, ctx) do
    seq([{:e, base} | Enum.map(fields, fn {_, x} -> {:e, x} end)], ctx, fn [bf | fs] ->
      rt(:update, [bf, field_map(fields, fs)])
    end)
  end

  def expr({:case, _, [scrutinee, arms]}, ctx) do
    {sf, ctx} = expr(scrutinee, ctx)

    {clauses, ctx} =
      Enum.map_reduce(arms, ctx, fn {pattern, body}, ctx ->
        {pf, inner} = pattern(pattern, ctx)
        {bf, inner} = body(body, inner)
        {{:clause, @a, [pf], [], bf}, scoped(ctx, inner)}
      end)

    no_arm = {:clause, @a, [{:var, @a, :_}], [], [rt(:no_arm!, [])]}
    {{:case, @a, sf, clauses ++ [no_arm]}, ctx}
  end

  def expr({:if, _, [c, t, e]}, ctx) do
    {cf, ctx} = expr(c, ctx)
    {tf, ctx} = body(t, ctx)
    {ef, ctx} = body(e, ctx)

    {{:case, @a, cf, [{:clause, @a, [lit(true)], [], tf}, {:clause, @a, [lit(false)], [], ef}]},
     ctx}
  end

  def expr({:fn, _, [params, body]}, ctx) do
    {vars, inner} = params(ctx, params)
    {bf, inner} = body(body, inner)
    {{:fun, @a, {:clauses, [{:clause, @a, vars, [], bf}]}}, scoped(ctx, inner)}
  end

  def expr({:block, _, _} = block, ctx) do
    case body(block, ctx) do
      {[one], ctx} -> {one, ctx}
      {forms, ctx} -> {{:block, @a, forms}, ctx}
    end
  end

  def expr({:always, _, [x]}, ctx) do
    {f, ctx} = expr(x, ctx)
    failed = remote(@hooks, :always_failed, [lit(Format.expr(x))])

    {{:case, @a, f,
      [{:clause, @a, [lit(true)], [], [unit()]}, {:clause, @a, [{:var, @a, :_}], [], [failed]}]},
     ctx}
  end

  def expr({:sometimes, _, [x]}, %{decl: nil} = ctx) do
    {f, ctx} = expr(x, ctx)
    {{:block, @a, [{:match, @a, {:var, @a, :_}, f}, unit()]}, ctx}
  end

  def expr({:sometimes, _, [x]}, ctx) do
    {f, ctx} = expr(x, ctx)
    held = remote(@hooks, :sometimes_held, [lit(ctx.decl), lit(Format.expr(x))])

    {{:case, @a, f,
      [{:clause, @a, [lit(true)], [], [held]}, {:clause, @a, [{:var, @a, :_}], [], [unit()]}]},
     ctx}
  end

  def expr({:jsx, _, _} = jsx, ctx), do: jsx(jsx, ctx)
  def expr({:annot, _, [x, _type]}, ctx), do: expr(x, ctx)

  defp unit, do: {:tuple, @a, []}

  defp field_map(fields, forms) do
    assocs =
      Enum.zip_with(fields, forms, fn {name, _}, f -> {:map_field_assoc, @a, lit(name), f} end)

    {:map, @a, assocs}
  end

  # Through `Rt.eq/2`: `=:=` never yields, so a value too large to walk is
  # refused before it is compared.
  defp binary(:==, l, r), do: rt(:eq, [l, r])
  defp binary(:!=, l, r), do: {:op, @a, :not, rt(:eq, [l, r])}
  defp binary(:<, l, r), do: {:op, @a, :<, l, r}
  defp binary(:>, l, r), do: {:op, @a, :>, l, r}
  defp binary(:<=, l, r), do: {:op, @a, :"=<", l, r}
  defp binary(:>=, l, r), do: {:op, @a, :>=, l, r}
  defp binary(:++, l, r), do: rt(:concat, [l, r])
  defp binary(:+, l, r), do: rt(:add, [l, r])
  defp binary(:-, l, r), do: rt(:sub, [l, r])
  defp binary(:*, l, r), do: rt(:mul, [l, r])
  defp binary(:/, l, r), do: rt(:div, [l, r])

  # ---------- sequencing ----------

  # `build` of the parts' forms, the parts evaluated left to right: every
  # part that may do something, except the last such, is bound to a fresh
  # variable first. A part is `{:e, node}` (an expression) or `{:f, form}`
  # (a form already lowered).
  defp seq(parts, ctx, build) do
    {forms, ctx} =
      Enum.map_reduce(parts, ctx, fn
        {:e, node}, ctx -> expr(node, ctx)
        {:f, form}, ctx -> {form, ctx}
      end)

    active = forms |> Enum.with_index() |> Enum.reject(fn {f, _} -> inert?(f) end)

    case active do
      [_, _ | _] ->
        {_, last} = List.last(active)

        {bound, {matches, ctx}} =
          forms
          |> Enum.with_index()
          |> Enum.map_reduce({[], ctx}, fn {f, i}, {matches, ctx} ->
            if i == last or inert?(f) do
              {f, {matches, ctx}}
            else
              {v, ctx} = fresh(ctx)
              {v, {[{:match, @a, v, f} | matches], ctx}}
            end
          end)

        {{:block, @a, Enum.reverse(matches) ++ [build.(bound)]}, ctx}

      _ ->
        {build.(forms), ctx}
    end
  end

  # A form whose evaluation does nothing but make its value.
  defp inert?({kind, _, _}) when kind in [:var, :integer, :atom, :string], do: true
  defp inert?({nil, _}), do: true
  defp inert?({:fun, _, _}), do: true
  defp inert?({:bin, _, elements}), do: Enum.all?(elements, &inert_element?/1)
  defp inert?({:tuple, _, items}), do: Enum.all?(items, &inert?/1)
  defp inert?({:cons, _, h, t}), do: inert?(h) and inert?(t)
  defp inert?(_), do: false

  defp inert_element?({:bin_element, _, f, _, _}), do: inert?(f)

  # ---------- names and calls ----------

  # A name by what it resolved to: a local's variable, a def as a function,
  # a variant without arguments, a constructor as a function.
  defp name(:local, name, ctx), do: {local(name, ctx), ctx}
  defp name({:def, def}, _name, ctx), do: def_value(def, ctx)
  defp name({:variant, owner, variant, _}, _name, ctx), do: {lit({:var, owner, variant, []}), ctx}

  defp name({:ctor_ref, owner, variant, arity}, _name, ctx) when arity in 1..8,
    do: {rt(:ctor, [lit(owner), lit(variant), lit(arity)]), ctx}

  defp name({:ctor_ref, owner, variant, arity}, _name, ctx) do
    {vars, ctx} = Enum.map_reduce(1..arity, ctx, fn _, ctx -> fresh(ctx) end)
    built = {:tuple, @a, [lit(:var), lit(owner), lit(variant), list(vars)]}
    {{:fun, @a, {:clauses, [{:clause, @a, vars, [], [built]}]}}, ctx}
  end

  defp name(res, name, _ctx),
    do: raise(ArgumentError, "unresolved name `#{name}`: #{inspect(res)}")

  defp local(name, ctx), do: {:var, @a, Map.fetch!(ctx.env, name)}

  # A def applied as a value: the image's own as `fun Mod:dN/K`; JSON's as a
  # closure passing the image's models; any other stdlib def as its function.
  defp def_value(def, ctx) do
    case ctx.names do
      %{^def => {fun, arity}} ->
        {{:fun, @a, {:function, lit(ctx.module), lit(fun), lit(arity)}}, ctx}

      _ when def in ["JSON.parse", "JSON.stringify"] ->
        {v, ctx} = fresh(ctx)
        f = if def == "JSON.parse", do: :parse, else: :stringify
        applied = remote(@json, f, [v, lit(nil), models(ctx)])
        {{:fun, @a, {:clauses, [{:clause, @a, [v], [], [applied]}]}}, ctx}

      _ ->
        {mod, fun, arity} = stdlib!(def)
        {{:fun, @a, {:function, lit(mod), lit(fun), lit(arity)}}, ctx}
    end
  end

  defp call(m, name, args, ctx) do
    parts = Enum.map(args, &{:e, &1})

    case m[:res] do
      :local ->
        seq([{:f, local(name, ctx)} | parts], ctx, fn [f | fs] -> {:call, @a, f, fs} end)

      {:def, def} ->
        call_def(def, m, args, parts, ctx)

      {kind, owner, variant, _} when kind in [:variant, :ctor_ref] ->
        seq(parts, ctx, &{:tuple, @a, [lit(:var), lit(owner), lit(variant), list(&1)]})

      # `Cmd.navigate(App, args…)`: an effect naming the app, then init's
      # arguments; the host resolves its URL (`Nobi.Lang.Types.Routes`).
      {:navigate, app, _params} ->
        seq(
          tl(parts),
          ctx,
          &rt(:cmd_effect, [lit("Cmd.navigate"), lit(nil), list([lit(app) | &1])])
        )

      # `Html.href(App, args…)`: `{:href, app, args}`, a link the page's
      # route table turns into a path (`NobiWeb.NobiHtml`).
      {:href, app, _params} ->
        seq(tl(parts), ctx, &{:tuple, @a, [lit(:href), lit(app), list(&1)]})

      # `Tx.delete(Model, id)`: the model by name, then the id
      # (`Nobi.Lang.Types.Store`).
      {:tx_delete, model} ->
        seq(tl(parts), ctx, fn [id] -> store_form("Tx.delete", model, [id]) end)

      res ->
        raise ArgumentError, "unresolved call of `#{name}`: #{inspect(res)}"
    end
  end

  # The image's def, else the stdlib's: JSON gets its call's types and the
  # image's models, a store form the model the checker settled.
  defp call_def(def, m, args, parts, ctx) do
    case ctx.names do
      %{^def => {fun, _}} when ctx.local? ->
        seq(parts, ctx, &{:call, @a, lit(fun), &1})

      %{^def => {fun, _}} ->
        seq(parts, ctx, &remote(ctx.module, fun, &1))

      _ when is_map_key(@store_forms, def) ->
        seq(parts, ctx, &store_form(def, m[:store], &1))

      _ ->
        stdlib_call(def, m, args, parts, ctx)
    end
  end

  defp stdlib_call("JSON.parse", m, _args, parts, ctx) do
    target =
      case m[:type] do
        {:applied, "Result", [t, _]} -> t
        _ -> nil
      end

    seq(parts, ctx, fn [s] -> remote(@json, :parse, [s, lit(target), models(ctx)]) end)
  end

  defp stdlib_call("JSON.stringify", _m, [arg], parts, ctx) do
    type = elem(arg, 1)[:type]
    seq(parts, ctx, fn [v] -> remote(@json, :stringify, [v, lit(type), models(ctx)]) end)
  end

  defp stdlib_call(def, _m, _args, parts, ctx) do
    {mod, fun, _} = stdlib!(def)
    seq(parts, ctx, &remote(mod, fun, &1))
  end

  # ---------- store forms ----------

  # A store form's value, its model (`meta[:store]`, from the checker;
  # `nil` only where it never settled: a lone expression) built in.
  # Their shapes are `Nobi.Lang.Rt`'s ("Store effects", Tx.Op).
  defp store_form("Cmd.store." <> _ = def, model, args),
    do: rt(:cmd_effect, [lit(def), lit(model), list(args)])

  defp store_form("Tx.insert", model, [row]), do: tx(:insert, model, [row])
  defp store_form("Tx.update", model, [id, row]), do: tx(:update, model, [id, row])
  defp store_form("Tx.delete", model, [id]), do: tx(:delete, model, [id])

  defp store_form("Store.get", model, [s, id]),
    do: remote(@data_hooks, :store_get, [s, lit(model), id])

  defp store_form("Store.list", model, [s]), do: remote(@data_hooks, :store_list, [s, lit(model)])

  defp tx(op, model, args), do: {:tuple, @a, [lit(:tx), lit(op), lit(model) | args]}

  # A store form applied as a value: a closure building it with the model.
  defp store_value(def, model, ctx) do
    {vars, ctx} =
      Enum.map_reduce(1..Map.fetch!(@store_forms, def), ctx, fn _, ctx -> fresh(ctx) end)

    {{:fun, @a, {:clauses, [{:clause, @a, vars, [], [store_form(def, model, vars)]}]}}, ctx}
  end

  defp stdlib!(def) do
    Stdlib.function_for(def) ||
      raise(ArgumentError, "`#{def}` is no def of the image or the stdlib")
  end

  # The image's model table: `__nobi__(models)`.
  defp models(%{local?: true}), do: {:call, @a, lit(:__nobi__), [lit(:models)]}
  defp models(ctx), do: remote(ctx.module, :__nobi__, [lit(:models)])

  # ---------- JSX ----------

  # `Rt:html_element(Tag, Attrs, Children)`, attributes then children
  # evaluated in order; a text child is its `Html.Text` already.
  defp jsx({:jsx, _, [tag, attrs, children]}, ctx) do
    attr_parts =
      Enum.map(attrs, fn
        {:text, _, text} -> {:f, lit(text)}
        {:expr, _, e} -> {:e, e}
        {:event, _, e} -> {:e, e}
      end)

    {child_parts, ctx} =
      Enum.map_reduce(children, ctx, fn
        {:text, text}, ctx -> {{:f, lit({:var, "Html", "Text", [text]})}, ctx}
        {:expr, e}, ctx -> {{:e, e}, ctx}
        {:element, el}, ctx -> {{:e, el}, ctx}
      end)

    seq(attr_parts ++ child_parts, ctx, fn fs ->
      {afs, cfs} = Enum.split(fs, length(attrs))

      pairs =
        Enum.zip_with(attrs, afs, fn attr, f -> {:tuple, @a, [lit(attr_name(attr)), f]} end)

      rt(:html_element, [lit(tag), list(pairs), list(cfs)])
    end)
  end

  defp attr_name({:event, event, _}), do: "on-" <> event
  defp attr_name({_, name, _}), do: name

  # ---------- patterns ----------

  # The pattern's form, its binders bound to fresh variables in order (a
  # name bound twice is its later binding, as Rust's `bind` extends).
  defp pattern(:wild, ctx), do: {{:var, @a, :_}, ctx}
  defp pattern({:pvar, name}, ctx), do: bind(ctx, name)
  defp pattern({:pint, n}, ctx), do: {lit(n), ctx}
  defp pattern({:pstr, s}, ctx), do: {lit(s), ctx}
  defp pattern({:pbool, b}, ctx), do: {lit(b), ctx}

  defp pattern({:ptuple, items}, ctx) do
    {fs, ctx} = Enum.map_reduce(items, ctx, &pattern/2)
    {{:tuple, @a, fs}, ctx}
  end

  defp pattern({:pvariant, name, args}, ctx) do
    {owner, variant} = split_variant(name)
    {fs, ctx} = Enum.map_reduce(args, ctx, &pattern/2)
    {{:tuple, @a, [lit(:var), lit(owner), lit(variant), list(fs)]}, ctx}
  end

  # `Owner.Variant`: the variant is the last segment (Rust's `names`).
  defp split_variant(name) do
    case :binary.matches(name, ".") do
      [] ->
        raise ArgumentError, "a variant pattern names its owner: `#{name}`"

      dots ->
        {at, 1} = List.last(dots)
        {binary_part(name, 0, at), binary_part(name, at + 1, byte_size(name) - at - 1)}
    end
  end

  # ---------- forms ----------

  @doc "A literal term's form (`:erl_parse.abstract/2`)."
  @spec lit(term()) :: tuple()
  def lit(term), do: :erl_parse.abstract(term, line: @a, encoding: :utf8)

  defp list(forms), do: List.foldr(forms, {nil, @a}, &{:cons, @a, &1, &2})

  defp remote(mod, fun, args), do: {:call, @a, {:remote, @a, lit(mod), lit(fun)}, args}
  defp rt(fun, args), do: remote(@rt, fun, args)
end
