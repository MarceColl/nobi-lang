defmodule Nobi.Lang.Graph do
  @moduledoc """
  Committed code as a system graph: its apps, its stored models, and which
  app reads or writes which model. Pure, over the checked trees of
  `Nobi.Lang.committed/1` (`%{name => %{typed, signature, ...}}`).

  ## Edges

  Each store form names its model in its node's `store:` meta, settled by
  the checker (`Nobi.Lang.Types.Store`); nothing here infers a model.
  `Cmd.store.insert/update/delete` and `Tx.insert/update/delete` write it,
  `Cmd.store.list/get` and `Store.get/list` read it, called or taken as a
  value. `Cmd.store.tx` names no model: its body's ops are its edges (its
  `Store.*` reads, its `Tx.*` writes).

  ## Attribution

  An app reaches its `init`, `update` and `view` and every def they
  reference (called or as a value), transitively. Each store form in a
  reached def is the app's edge, so a helper shared by two apps gives both
  the edge, and a def no app reaches gives none.
  """

  alias Nobi.Lang.Types.Store

  @type edge :: %{from: String.t(), to: String.t(), kind: :reads | :writes}
  @type t :: %{
          apps: [%{symbol: String.t(), routes: [String.t()]}],
          stores: [%{symbol: String.t(), fields: [String.t()]}],
          edges: [edge]
        }

  @reads ~w(Cmd.store.list Cmd.store.get Store.get Store.list)
  # `Tx.delete` resolves as `{:tx_delete, model}`, not as a def (`use_of/2`).
  @writes ~w(Cmd.store.insert Cmd.store.update Cmd.store.delete Tx.insert Tx.update)

  @doc "The graph of `committed` (`Nobi.Lang.committed/1`'s map); see the moduledoc."
  @spec of(%{String.t() => map()}) :: t
  def of(committed) do
    apps = for {name, %{signature: :app}} <- committed, do: name
    defs = def_uses(committed)

    %{
      apps: for(app <- Enum.sort(apps), do: %{symbol: app, routes: routes(committed, app)}),
      stores:
        for(
          {name, %{signature: {:model, fields} = sig}} <- Enum.sort(committed),
          Store.stored?(sig),
          do: %{symbol: name, fields: for({field, _, _} <- fields, do: field)}
        ),
      edges:
        apps
        |> Enum.flat_map(fn app -> edges(app, defs) end)
        |> Enum.uniq()
        |> Enum.sort_by(&{&1.from, &1.to, &1.kind})
    }
  end

  @doc """
  A route's pattern as written: `/` for none, else each segment as `/lit`
  or `/:param` (`Nobi.Lang.Codegen`'s route `segments`).
  """
  @spec pattern([Nobi.Lang.Ast.segment()]) :: String.t()
  def pattern([]), do: "/"

  def pattern(segments) do
    Enum.map_join(segments, fn
      {:lit, s} -> "/" <> s
      {:param, n} -> "/:" <> n
    end)
  end

  # The patterns of every route opening `app`, by routes name then
  # declaration order, each once.
  defp routes(committed, app) do
    for(
      {_name, %{signature: {:routes, routes}}} <- Enum.sort(committed),
      {segments, ^app} <- routes,
      do: pattern(segments)
    )
    |> Enum.uniq()
  end

  defp edges(app, defs) do
    roots = for part <- ~w(init update view), do: "#{app}.#{part}"

    for name <- reach(roots, defs, MapSet.new()),
        {kind, model} <- defs[name].effects,
        do: %{from: app, to: model, kind: kind}
  end

  # The defs reachable from `pending` through `calls`.
  defp reach([], _defs, seen), do: MapSet.to_list(seen)

  defp reach([name | rest], defs, seen) do
    case defs do
      %{^name => %{calls: calls}} ->
        if MapSet.member?(seen, name),
          do: reach(rest, defs, seen),
          else: reach(calls ++ rest, defs, MapSet.put(seen, name))

      _ ->
        reach(rest, defs, seen)
    end
  end

  # Each committed def's referenced names and store effects, from its tree.
  defp def_uses(committed) do
    for {name, %{typed: {:def, _, _} = typed}} <- committed, into: %{} do
      {calls, effects} = uses(typed, {[], []})
      {name, %{calls: Enum.uniq(calls), effects: Enum.uniq(effects)}}
    end
  end

  defp uses({kind, meta, args}, acc) when is_atom(kind) and is_list(meta) and is_list(args),
    do: uses(args, use_of(meta, acc))

  defp uses(list, acc) when is_list(list), do: Enum.reduce(list, acc, &uses/2)
  defp uses(tuple, acc) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> uses(acc)
  defp uses(_, acc), do: acc

  # Only a checked node's meta (a keyword list) resolves a name.
  defp use_of(meta, {calls, effects} = acc) do
    if Keyword.keyword?(meta) do
      case {meta[:res], meta[:store]} do
        {{:tx_delete, model}, _} ->
          {calls, [{:writes, model} | effects]}

        {{:def, form}, model} when form in @reads and is_binary(model) ->
          {calls, [{:reads, model} | effects]}

        {{:def, form}, model} when form in @writes and is_binary(model) ->
          {calls, [{:writes, model} | effects]}

        {{:def, def}, _} when is_binary(def) ->
          {[def | calls], effects}

        _ ->
          acc
      end
    else
      acc
    end
  end
end
