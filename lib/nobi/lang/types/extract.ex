defmodule Nobi.Lang.Types.Extract do
  @moduledoc """
  Syntactic extraction (ported from `types/extract.rs`): annotation-derived
  signatures and an over-approximated dependency set. Neither looks at a
  dependency.
  """

  alias Nobi.Lang.Ast

  @type signature ::
          {:def, [Ast.type()], Ast.type(), [String.t()]}
          | {:model, [{String.t(), Ast.type(), default()}]}
          | {:type, [String.t()], [{String.t(), [Ast.type()]}]}
          | {:routes, [Ast.route()]}
          | :app
          | :test

  @typedoc """
  A model field's default: `:none`, or its constant expression as written
  (`Nobi.Lang.Types.Store.constant?/1`), without positions, so a
  signature is the same wherever the model was parsed. Its value is
  `Nobi.Lang.Rt.constant/1` of it.
  """
  @type default :: :none | Ast.node_()

  @builtin_named ~w(Int Float String Bool Uuid Unit Store Href)
  @builtin_applied %{"List" => 1, "Map" => 2, "Cmd" => 1, "Html" => 1}

  @doc "Names that are never dependencies in type position."
  def builtin_named, do: @builtin_named

  @doc "Builtin applied type heads and their arities."
  def builtin_applied, do: @builtin_applied

  @doc "The segment after the last `.`, or the whole name."
  @spec last_segment(String.t()) :: String.t()
  def last_segment(name), do: name |> String.split(".") |> List.last()

  @doc "Everything before the last `.`, or the whole name if it has none."
  @spec owner_of(String.t()) :: String.t()
  def owner_of(name) do
    case String.split(name, ".") do
      [_] -> name
      parts -> parts |> Enum.drop(-1) |> Enum.join(".")
    end
  end

  @doc "A dotted name whose last segment is capitalised names a variant."
  @spec variant_name?(String.t()) :: boolean
  def variant_name?(name),
    do: String.contains?(name, ".") and Ast.capitalised?(last_segment(name))

  @doc """
  What a declaration offers others. A def's is its parameter types, return
  type and parameter names: a route matches `init`'s parameters by name, so
  renaming one changes the signature and checks its dependents again.
  """
  @spec signature(Ast.decl()) :: signature
  def signature({:def, _, [_, params, ret, _]}),
    do: {:def, Enum.map(params, &elem(&1, 1)), ret, Enum.map(params, &elem(&1, 0))}

  def signature({:defroutes, _, [_, routes]}), do: {:routes, routes}

  def signature({:defmodel, _, [_, fields]}),
    do: {:model, Enum.map(fields, fn {f, t, d} -> {f, t, Ast.without_positions(d)} end)}

  def signature({:deftype, _, [_, params, variants]}), do: {:type, params, variants}
  def signature({:defapp, _, _}), do: :app
  def signature({:deftest, _, _}), do: :test

  @doc "Every symbol this declaration might reference."
  @spec deps(Ast.decl()) :: MapSet.t(String.t())
  def deps(decl), do: decl |> collect() |> MapSet.new()

  defp collect({:def, _, [_, params, ret, body]}) do
    Enum.flat_map(params, &type_deps(elem(&1, 1), [])) ++ type_deps(ret, []) ++ expr(body)
  end

  defp collect({:defmodel, _, [_, fields]}) do
    Enum.flat_map(fields, fn
      {_, t, :none} -> type_deps(t, [])
      {_, t, d} -> type_deps(t, []) ++ expr(d)
    end)
  end

  defp collect({:deftype, _, [_, params, variants]}) do
    for {_, args} <- variants, a <- args, d <- type_deps(a, params), do: d
  end

  defp collect({:defapp, _, [name]}),
    do: for(s <- ~w(init update view Model Msg), do: "#{name}.#{s}")

  defp collect({:deftest, _, [_, body]}), do: expr(body)

  defp collect({:defroutes, _, [_, routes]}),
    do: Enum.flat_map(routes, fn {_, app} -> [app, "#{app}.init"] end)

  defp type_deps({:named, n}, params) do
    if n in @builtin_named or n in params, do: [], else: [n]
  end

  defp type_deps({:applied, n, args}, params) do
    head = if Map.has_key?(@builtin_applied, n), do: [], else: [n]
    head ++ Enum.flat_map(args, &type_deps(&1, params))
  end

  defp type_deps({:arrow, ps, r}, params),
    do: Enum.flat_map(ps, &type_deps(&1, params)) ++ type_deps(r, params)

  defp type_deps({:tuple, items}, params), do: Enum.flat_map(items, &type_deps(&1, params))
  defp type_deps({:var, _}, _), do: []

  defp name_deps(name) do
    cond do
      not String.contains?(name, ".") -> []
      variant_name?(name) -> [owner_of(name)]
      true -> [name]
    end
  end

  defp pattern_deps({:pvariant, n, args}),
    do: [owner_of(n) | Enum.flat_map(args, &pattern_deps/1)]

  defp pattern_deps({:ptuple, items}), do: Enum.flat_map(items, &pattern_deps/1)
  defp pattern_deps(_), do: []

  defp exprs(list), do: Enum.flat_map(list, &expr/1)

  defp expr({k, _, [_]}) when k in [:int, :float, :str, :bool], do: []
  defp expr({:name, _, [n]}), do: name_deps(n)
  defp expr({k, _, items}) when k in [:list, :tuple], do: exprs(items)
  defp expr({:map, _, entries}), do: Enum.flat_map(entries, fn {k, v} -> expr(k) ++ expr(v) end)
  defp expr({:bin, _, [_, l, r]}), do: expr(l) ++ expr(r)
  defp expr({k, _, [e]}) when k in [:not, :neg, :always, :sometimes], do: expr(e)

  defp expr({:call, _, [form, [{:name, _, [app]} | args]]})
       when form in ["Cmd.navigate", "Html.href"],
       do: [app, "#{app}.init" | exprs(args)]

  defp expr({:call, _, ["Tx.delete", [{:name, _, [model]} | args]]}),
    do: [model | exprs(args)]

  defp expr({:call, _, [n, args]}), do: name_deps(n) ++ exprs(args)
  defp expr({:field, _, [e, _]}), do: expr(e)

  defp expr({:construct, _, [model, fields]}),
    do: [model | Enum.flat_map(fields, &expr(elem(&1, 1)))]

  defp expr({:update, _, [model, base, fields]}),
    do: [model] ++ expr(base) ++ Enum.flat_map(fields, &expr(elem(&1, 1)))

  defp expr({:case, _, [scrut, arms]}),
    do: expr(scrut) ++ Enum.flat_map(arms, fn {p, e} -> pattern_deps(p) ++ expr(e) end)

  defp expr({:if, _, [c, t, e]}), do: expr(c) ++ expr(t) ++ expr(e)

  defp expr({:fn, _, [params, body]}),
    do: Enum.flat_map(params, &type_deps(elem(&1, 1), [])) ++ expr(body)

  defp expr({:block, _, [stmts, last]}) do
    Enum.flat_map(stmts, fn
      {:bind, _, e} -> expr(e)
      {:expr, e} -> expr(e)
    end) ++ expr(last)
  end

  defp expr({:jsx, _, [_tag, attrs, children]}), do: jsx(attrs, children)
  defp expr({:annot, _, [e, t]}), do: expr(e) ++ type_deps(t, [])

  defp jsx(attrs, children) do
    Enum.flat_map(attrs, fn
      {:text, _, _} -> []
      {:expr, _, e} -> expr(e)
      {:event, _, e} -> expr(e)
    end) ++
      Enum.flat_map(children, fn
        {:text, _} -> []
        {:expr, e} -> expr(e)
        {:element, {:jsx, _, [_, a, c]}} -> jsx(a, c)
      end)
  end
end
