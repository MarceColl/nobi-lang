defmodule Kinoko.Lang.Types.Store do
  @moduledoc """
  The store's rules in the checker: stored models, field defaults, and the
  model each store form works on.

  ## Stored models

  A model is *stored* when it declares `id : Uuid` (`stored?/1`): the store
  mints the id, so only such a model has rows. `Cmd.store.*`, `Tx.insert`,
  `Tx.update`, `Store.get` and `Store.list` work on one stored model; on
  anything else they are `"not-stored"`.

  ## Which model a form works on

  Each form names its model by a position of its type (`@forms`): a row
  argument (`Cmd.store.insert`, `Cmd.store.update`, `Tx.*`), the callback's
  `List<M>`/`Option<M>` (`Cmd.store.list`, `get`, `delete`), or the result's
  (`Store.get`, `Store.list`). That position is read once inference has
  settled (`check_form/3`, from `finalize`), so a read's model comes from the
  type its result is used at: an annotation, a declared return type, a
  later `Tx.update` of it. One that nothing settles is `"cannot-infer"`,
  with the annotation that fixes it. In a lone expression (`eval`) an open
  model stays open.

  A form whose model settled carries it in its node's meta as `store:`
  (the model's name), for codegen. Applied as a value (`List.map(rows,
  Tx.insert)`) the reference node carries it the same way.

  `Cmd.store.tx` names no model: a transaction's ops each name theirs.

  `Tx.delete(Model, id)` is a special form, like `Cmd.navigate`: its first
  argument is the stored model's name, read as a signature (`Ctx.dget/2`),
  never a value. The call's `res:` is `{:tx_delete, model}`, its model
  argument's `{:model, model}`, and it carries `store:` too. Referenced as a
  value it is refused (`"bad-tx-delete"`, in `Kinoko.Lang.Types.Check`'s
  synthesis): its model is its call's.

  ## Defaults

  A field's default is a constant (`constant?/1`): a literal, a negated
  integer literal, a list, map or tuple of constants, or a variant
  (`Option.None`, `A.S.On`) or a variant applied to constants
  (`Option.Some(1)`). Anything else, a call or a reference to another
  symbol, is `"bad-default"`, and so is a constant not of the field's type.
  Defaults only fill rows written before their field existed; a
  construction still lists every field. An `Option<…>` field takes no
  default (`"bad-default"`): it reads as `Option.None` when absent, since a
  stored `NULL` cannot tell `None` from absent.
  """

  alias Kinoko.Lang.{Ast, Format}
  alias Kinoko.Lang.Types.{Check, Extract, Infer, Quote}
  alias Kinoko.Lang.Types.Check.Ctx

  import Kinoko.Lang.Types.Check.Tree, only: [ty: 1, res: 1, put_ann: 3]

  # Where each form's model is in its (instantiated) type `{:arrow, params, ret}`.
  @forms %{
    "Cmd.store.insert" => {:param, 0},
    "Cmd.store.update" => {:param, 1},
    "Cmd.store.list" => {:callback, 0, "List"},
    "Cmd.store.get" => {:callback, 1, "Option"},
    "Cmd.store.delete" => {:callback, 1, "Option"},
    "Tx.insert" => {:param, 0},
    "Tx.update" => {:param, 1},
    "Store.get" => {:result, "Option"},
    "Store.list" => {:result, "List"}
  }

  @doc "The stdlib forms that work on one stored model."
  @spec forms() :: [String.t()]
  def forms, do: Map.keys(@forms)

  @doc "Whether a signature is a stored model's: a model that declares `id : Uuid`."
  @spec stored?(term()) :: boolean()
  def stored?({:model, fields}), do: Enum.any?(fields, &match?({"id", {:named, "Uuid"}, _}, &1))
  def stored?(_), do: false

  # ---------- defaults ----------

  @doc "Whether `e` is a constant a default may be (see \"Defaults\")."
  @spec constant?(term()) :: boolean()
  def constant?({k, _, [_]}) when k in [:int, :str, :bool], do: true
  def constant?({:neg, _, [{:int, _, [_]}]}), do: true
  def constant?({k, _, items}) when k in [:list, :tuple], do: Enum.all?(items, &constant?/1)

  def constant?({:map, _, entries}),
    do: Enum.all?(entries, fn {k, v} -> constant?(k) and constant?(v) end)

  def constant?({:name, _, [name]}), do: Extract.variant_name?(name)

  def constant?({:call, _, [name, args]}),
    do: Extract.variant_name?(name) and Enum.all?(args, &constant?/1)

  def constant?(_), do: false

  @doc "A field's default (`:none` or a constant of the field's type `t`), checked."
  def check_default(ctx, _field, _t, :none), do: ctx

  # A stored NULL cannot tell `None` from "written before the field
  # existed", so an `Option` field always reads as `None` when absent.
  def check_default(ctx, field, {:applied, "Option", [_]}, _default) do
    Ctx.error(
      ctx,
      "bad-default",
      "`#{field}`: an Option field reads as Option.None when absent; drop the default " <>
        "or use a non-Option type with a default"
    )
  end

  def check_default(ctx, field, t, default) do
    if constant?(default) do
      case not_variants(ctx, default) do
        {[], ctx} -> typed_default(ctx, field, t, default)
        {names, ctx} -> not_variant_default(ctx, field, names)
      end
    else
      Ctx.error(
        ctx,
        "bad-default",
        "the default of `#{field}` must be a constant — a literal, or a list, map, tuple or variant " <>
          "of constants; `#{Quote.expr(default)}` is not (no calls, no references to other symbols)"
      )
    end
  end

  # The variant names a constant uses that are no variant of their owner
  # type (a model's name, a def's type's, …), each read as a signature.
  defp not_variants(ctx, default) do
    default
    |> variant_names([])
    |> Enum.reverse()
    |> Enum.uniq()
    |> Enum.flat_map_reduce(ctx, fn name, ctx ->
      case Ctx.dget(ctx, Extract.owner_of(name)) do
        {{:type, _, variants}, ctx} ->
          if List.keymember?(variants, Extract.last_segment(name), 0),
            do: {[], ctx},
            else: {[name], ctx}

        {_, ctx} ->
          {[name], ctx}
      end
    end)
  end

  defp variant_names({:name, _, [name]}, acc), do: [name | acc]

  defp variant_names({:call, _, [name, args]}, acc),
    do: Enum.reduce(args, [name | acc], &variant_names/2)

  defp variant_names({k, _, items}, acc) when k in [:list, :tuple],
    do: Enum.reduce(items, acc, &variant_names/2)

  defp variant_names({:map, _, entries}, acc),
    do: Enum.reduce(entries, acc, fn {k, v}, acc -> variant_names(v, variant_names(k, acc)) end)

  defp variant_names(_, acc), do: acc

  defp not_variant_default(ctx, field, names) do
    shown = Enum.map_join(names, ", ", &"`#{&1}`")

    Ctx.error(
      ctx,
      "bad-default",
      "the default of `#{field}` names #{shown}, which is no variant of a type — a default is a " <>
        "constant: a literal, or a list, map, tuple or variant (as `Option.None`) of constants"
    )
  end

  defp typed_default(ctx, field, t, default) do
    {s, ctx} = Check.synth(ctx, default)
    {written, ctx} = Ctx.written(ctx, t)

    # Tried on a copy: a mismatch is this rule's error, not the generic one.
    case Infer.unify(ctx.infer, ty(s), written, default) do
      {:ok, infer} ->
        %{ctx | infer: infer}

      {:error, _, _} ->
        Ctx.error(
          ctx,
          "bad-default",
          "the default of `#{field}` is `#{Quote.expr(default)}`, which is not a " <>
            "`#{Format.type(t)}` — a default has its field's type"
        )
    end
  end

  # ---------- store forms ----------

  @doc """
  `e`, a node being finalized whose type resolved to `t`: when it is a store
  form (a call of one, or one referenced as a value), the model it works on
  must be a stored model, and the node carries it as `store:`. Every other
  node is returned as it is.
  """
  def check_form(ctx, {kind, m, args} = e, t) when kind in [:call, :name] do
    with {:def, name} <- res(e),
         {:ok, where} <- Map.fetch(@forms, name) do
      {arrow, ctx} = form_type(ctx, e, t)

      case model_at(where, arrow) do
        {:ok, model} ->
          case stored_model(ctx, e, model) do
            {:ok, name, ctx} -> {{kind, Keyword.put(m, :store, name), args}, ctx}
            {:error, ctx} -> {e, ctx}
          end

        :open ->
          {e, open_model(ctx, e, name, where)}
      end
    else
      _ -> {e, ctx}
    end
  end

  def check_form(ctx, e, _t), do: {e, ctx}

  # ---------- Tx.delete(Model, id) ----------

  @tx_example "`Tx.delete(Forum.Post, id)`"

  @doc false
  def tx_delete_why,
    do:
      "names its stored model as its first argument, then the id, as in #{@tx_example}: call it, " <>
        "rather than apply it as a value"

  @doc """
  `Tx.delete(Model, id)`, annotated `Tx.Op`: `Model` a stored model, `id` a
  `Uuid`.
  """
  def synth_tx_delete(ctx, {:call, m, [name, [{:name, _, [model]} = a, id]]} = e) do
    if Ast.capitalised?(Extract.last_segment(model)) do
      {s, ctx} = Check.synth(ctx, id)
      ctx = Ctx.unify!(ctx, ty(s), {:named, "Uuid"}, id)
      a = put_ann(a, {:named, "Unit"}, {:model, model})

      {m, ctx} =
        case stored_model(ctx, e, {:named, model}) do
          {:ok, model, ctx} -> {Keyword.put(m, :store, model), ctx}
          {:error, ctx} -> {m, ctx}
        end

      {put_ann({:call, m, [name, [a, s]]}, {:named, "Tx.Op"}, {:tx_delete, model}), ctx}
    else
      tx_delete_failed(ctx, e)
    end
  end

  def synth_tx_delete(ctx, e), do: tx_delete_failed(ctx, e)

  defp tx_delete_failed(ctx, e) do
    message =
      "`#{Quote.expr(e)}`: `Tx.delete` names its stored model, then the id, as in #{@tx_example}"

    {call, ctx} = ctx |> Ctx.error("bad-tx-delete", message) |> Check.unchecked(e)
    {put_ann(call, {:named, "Tx.Op"}, nil), ctx}
  end

  # The form's type, resolved: a call's is its arguments' to its own; a
  # reference's its own.
  defp form_type(ctx, {:call, _, [_, args]}, t) do
    {params, ctx} =
      Enum.map_reduce(args, ctx, fn arg, ctx ->
        Ctx.resolve_deep(ctx, ty(arg), fn -> Quote.expr(arg) end)
      end)

    {{:arrow, params, t}, ctx}
  end

  defp form_type(ctx, {:name, _, _}, t), do: {t, ctx}

  defp model_at(where, {:arrow, params, ret}) do
    found =
      case where do
        {:param, i} ->
          Enum.at(params, i)

        {:callback, i, wrapper} ->
          case Enum.at(params, i) do
            {:arrow, [{:applied, ^wrapper, [model]} | _], _} -> model
            _ -> nil
          end

        {:result, wrapper} ->
          case ret do
            {:applied, ^wrapper, [model]} -> model
            _ -> nil
          end
      end

    if found == nil or Infer.contains_uvar?(found), do: :open, else: {:ok, found}
  end

  defp model_at(_where, _t), do: :open

  defp stored_model(ctx, e, {:named, name} = model) do
    case Ctx.dget(ctx, name) do
      {{:model, _} = sig, ctx} ->
        if stored?(sig),
          do: {:ok, name, ctx},
          else:
            {:error,
             Ctx.error(
               ctx,
               "not-stored",
               "`#{Quote.expr(e)}`: `#{name}` is not a stored model — the store keeps only models " <>
                 "that declare `id : Uuid`; add `id : Uuid` to `#{name}`"
             )}

      {_, ctx} ->
        {:error, not_a_model(ctx, e, model)}
    end
  end

  defp stored_model(ctx, e, model), do: {:error, not_a_model(ctx, e, model)}

  defp not_a_model(ctx, e, model) do
    Ctx.error(
      ctx,
      "not-stored",
      "`#{Quote.expr(e)}` works on `#{Quote.type(model)}`, which is not a model — the store keeps " <>
        "rows of a stored model (a defmodel that declares `id : Uuid`)"
    )
  end

  # A model nothing settled: open in a lone expression; else, if nothing
  # else failed, which annotation settles it.
  defp open_model(ctx, e, name, where) do
    if ctx.infer.lone_expression or not Ctx.no_errors?(ctx) do
      ctx
    else
      hint =
        case where do
          {:result, wrapper} -> ", as in `(#{Quote.expr(e)} : #{wrapper}<App.Row>)`"
          _ -> ""
        end

      Ctx.error(
        ctx,
        "cannot-infer",
        "cannot infer which model `#{Quote.expr(e)}` works on — annotate it#{hint}, or use its " <>
          "result where its type is declared (`#{name}` takes its model from the type expected of it)"
      )
    end
  end
end
