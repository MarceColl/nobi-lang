defmodule Kinoko.Lang.Types.Check.Tree do
  @moduledoc """
  The checked tree: each expression node's meta carries `type:` and `res:`,
  and `map_children/3` is the one walk over every expression form that
  `finalize` and `unchecked` share (Rust's `map_kind`/`map_block`/`map_jsx`).
  """

  @doc "The type in a checked node's meta."
  def ty({_, m, _}), do: Keyword.fetch!(m, :type)

  @doc "The resolution in a checked node's meta (`nil` when none)."
  def res({_, m, _}), do: Keyword.get(m, :res)

  @doc "`node` with `type:` and `res:` set in its meta."
  def put_ann({k, m, a}, t, res), do: {k, m |> Keyword.put(:type, t) |> Keyword.put(:res, res), a}

  @doc """
  `node` with every child expression mapped by `f` (`child, acc -> {child,
  acc}`), in the order written. An inner JSX element is not an expression:
  its own expressions are mapped, the element is not.
  """
  def map_children({kind, m, args}, acc, f) do
    {args, acc} = map_args(kind, args, acc, f)
    {{kind, m, args}, acc}
  end

  defp map_args(k, args, acc, _f) when k in [:int, :str, :bool, :name], do: {args, acc}
  defp map_args(k, items, acc, f) when k in [:list, :tuple], do: Enum.map_reduce(items, acc, f)

  defp map_args(:map, entries, acc, f) do
    Enum.map_reduce(entries, acc, fn {k, v}, acc ->
      {k, acc} = f.(k, acc)
      {v, acc} = f.(v, acc)
      {{k, v}, acc}
    end)
  end

  defp map_args(:bin, [op, l, r], acc, f) do
    {l, acc} = f.(l, acc)
    {r, acc} = f.(r, acc)
    {[op, l, r], acc}
  end

  defp map_args(k, [x], acc, f) when k in [:not, :neg, :always, :sometimes] do
    {x, acc} = f.(x, acc)
    {[x], acc}
  end

  defp map_args(:call, [n, xs], acc, f) do
    {xs, acc} = Enum.map_reduce(xs, acc, f)
    {[n, xs], acc}
  end

  defp map_args(:field, [x, n], acc, f) do
    {x, acc} = f.(x, acc)
    {[x, n], acc}
  end

  defp map_args(:construct, [model, fields], acc, f) do
    {fields, acc} = map_fields(fields, acc, f)
    {[model, fields], acc}
  end

  defp map_args(:update, [model, base, fields], acc, f) do
    {base, acc} = f.(base, acc)
    {fields, acc} = map_fields(fields, acc, f)
    {[model, base, fields], acc}
  end

  defp map_args(:case, [s, arms], acc, f) do
    {s, acc} = f.(s, acc)

    {arms, acc} =
      Enum.map_reduce(arms, acc, fn {p, b}, acc ->
        {b, acc} = f.(b, acc)
        {{p, b}, acc}
      end)

    {[s, arms], acc}
  end

  defp map_args(:if, [c, t, o], acc, f) do
    {c, acc} = f.(c, acc)
    {t, acc} = f.(t, acc)
    {o, acc} = f.(o, acc)
    {[c, t, o], acc}
  end

  defp map_args(:fn, [params, body], acc, f) do
    {body, acc} = f.(body, acc)
    {[params, body], acc}
  end

  defp map_args(:block, [stmts, last], acc, f) do
    {stmts, acc} = Enum.map_reduce(stmts, acc, &map_stmt(&1, &2, f))
    {last, acc} = f.(last, acc)
    {[stmts, last], acc}
  end

  defp map_args(:jsx, [tag, attrs, children], acc, f) do
    {attrs, acc} =
      Enum.map_reduce(attrs, acc, fn
        {:text, _, _} = a, acc ->
          {a, acc}

        {k, n, x}, acc when k in [:expr, :event] ->
          {x, acc} = f.(x, acc)
          {{k, n, x}, acc}
      end)

    {children, acc} =
      Enum.map_reduce(children, acc, fn
        {:text, _} = c, acc ->
          {c, acc}

        {:expr, x}, acc ->
          {x, acc} = f.(x, acc)
          {{:expr, x}, acc}

        {:element, {:jsx, em, inner}}, acc ->
          {inner, acc} = map_args(:jsx, inner, acc, f)
          {{:element, {:jsx, em, inner}}, acc}
      end)

    {[tag, attrs, children], acc}
  end

  defp map_args(:annot, [x, t], acc, f) do
    {x, acc} = f.(x, acc)
    {[x, t], acc}
  end

  defp map_fields(fields, acc, f) do
    Enum.map_reduce(fields, acc, fn {n, x}, acc ->
      {x, acc} = f.(x, acc)
      {{n, x}, acc}
    end)
  end

  @doc "A block statement with its expression mapped by `f`."
  def map_stmt({:bind, n, x}, acc, f) do
    {x, acc} = f.(x, acc)
    {{:bind, n, x}, acc}
  end

  def map_stmt({:expr, x}, acc, f) do
    {x, acc} = f.(x, acc)
    {{:expr, x}, acc}
  end
end
