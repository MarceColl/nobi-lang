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

  `Cmd.store.tx` and `Tx.delete` name no model: a transaction's ops each
  name theirs, and `Tx.delete` takes an id alone.

  ## Defaults

  A field's default is a constant (`constant?/1`): a literal, a negated
  integer literal, a list, map or tuple of constants, or a variant
  (`Option.None`, `A.S.On`) or a variant applied to constants
  (`Option.Some(1)`). Anything else, a call or a reference to another
  symbol, is `"bad-default"`, and so is a constant not of the field's type.
  Defaults only fill rows written before their field existed; a
  construction still lists every field.
  """

  alias Kinoko.Lang.Format
  alias Kinoko.Lang.Types.{Check, Extract, Infer, Quote}
  alias Kinoko.Lang.Types.Check.Ctx

  import Kinoko.Lang.Types.Check.Tree, only: [ty: 1, res: 1]

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

  def check_default(ctx, field, t, default) do
    if constant?(default) do
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
    else
      Ctx.error(
        ctx,
        "bad-default",
        "the default of `#{field}` must be a constant — a literal, or a list, map, tuple or variant " <>
          "of constants; `#{Quote.expr(default)}` is not (no calls, no references to other symbols)"
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
