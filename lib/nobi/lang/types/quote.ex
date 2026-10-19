defmodule Nobi.Lang.Types.Quote do
  @moduledoc """
  What an error message quotes of a program (ported from `types/quote.rs`):
  at most `limit/0` characters, then `…`. An expression is formatted from a
  copy of its first nodes, so a quote costs the same however large what it is
  cut from; formatting the whole and cutting after made an error at every
  level of a deep failing nest format the nest below it again.
  """

  alias Nobi.Lang.Format
  alias Nobi.Lang.Types.Infer

  @limit 200
  @elided "…"

  @doc "The most characters a message quotes of an expression or a type."
  def limit, do: @limit

  @doc "A type, formatted for a message and cut at the limit."
  @spec type(term()) :: String.t()
  def type(t), do: Infer.format_itype(Infer.new(), t)

  @doc "An expression, formatted and cut for a message."
  @spec expr(tuple()) :: String.t()
  def expr(e) do
    {copy, _} = expr(e, @limit + 1)
    cut(Format.expr(copy))
  end

  @doc "A pattern, formatted and cut for a message."
  @spec pattern(term()) :: String.t()
  def pattern(p) do
    {copy, _} = pat(p, @limit + 1)
    cut(Format.pattern(copy))
  end

  @doc "`s`, cut at the limit characters then `…`."
  @spec cut(String.t()) :: String.t()
  def cut(s) do
    case s |> String.to_charlist() |> Enum.split(@limit) do
      {_, []} -> s
      {head, _} -> List.to_string(head) <> @elided
    end
  end

  @doc "The first `n` code points of `s` (Rust counts code points, not graphemes)."
  def take(s, n), do: s |> String.to_charlist() |> Enum.take(n) |> List.to_string()

  @doc "The number of code points in `s`."
  def length(s), do: s |> String.to_charlist() |> Kernel.length()

  defp short(s), do: take(s, @limit)
  defp elided, do: {:name, [], [@elided]}

  # Copies of an expression's first `left` nodes, in the order they are
  # written, each name and literal cut to `short`; whatever follows is `…`.
  # Every function returns {copy, nodes left}.

  # Each of `items` copied by `each` while nodes are left, then one
  # `elide` for the rest, which is never looked at.
  defp seq(items, left, each, elide) do
    {out, left, _} =
      Enum.reduce_while(items, {[], left, true}, fn item, {out, left, _} ->
        if left == 0 do
          {:halt, {[elide | out], left, false}}
        else
          {copy, left} = each.(item, left)
          {:cont, {[copy | out], left, true}}
        end
      end)

    {Enum.reverse(out), left}
  end

  defp exprs(items, left), do: seq(items, left, &expr/2, elided())

  defp fields(fs, left) do
    seq(
      fs,
      left,
      fn {n, e}, left ->
        {e, left} = expr(e, left)
        {{short(n), e}, left}
      end,
      {@elided, elided()}
    )
  end

  defp expr(_e, 0), do: {elided(), 0}

  defp expr({kind, m, args}, left) do
    left = left - 1
    {args, left} = args(kind, args, left)
    {{kind, strip_meta(m), args}, left}
  end

  defp strip_meta(_), do: []

  defp args(:int, a, left), do: {a, left}
  defp args(:float, a, left), do: {a, left}
  defp args(:bool, a, left), do: {a, left}
  defp args(:str, [s], left), do: {[short(s)], left}
  defp args(:name, [n], left), do: {[short(n)], left}
  defp args(:list, items, left), do: exprs(items, left)
  defp args(:tuple, items, left), do: exprs(items, left)

  defp args(:map, entries, left) do
    seq(
      entries,
      left,
      fn {k, v}, left ->
        {k, left} = expr(k, left)
        {v, left} = expr(v, left)
        {{k, v}, left}
      end,
      {elided(), elided()}
    )
  end

  defp args(:bin, [op, l, r], left) do
    {l, left} = expr(l, left)
    {r, left} = expr(r, left)
    {[op, l, r], left}
  end

  defp args(k, [x], left) when k in [:not, :neg, :always, :sometimes] do
    {x, left} = expr(x, left)
    {[x], left}
  end

  defp args(:call, [n, xs], left) do
    {xs, left} = exprs(xs, left)
    {[short(n), xs], left}
  end

  defp args(:field, [x, f], left) do
    {x, left} = expr(x, left)
    {[x, short(f)], left}
  end

  defp args(:construct, [model, fs], left) do
    {fs, left} = fields(fs, left)
    {[short(model), fs], left}
  end

  defp args(:update, [model, base, fs], left) do
    {base, left} = expr(base, left)
    {fs, left} = fields(fs, left)
    {[short(model), base, fs], left}
  end

  defp args(:case, [scrutinee, arms], left) do
    {scrutinee, left} = expr(scrutinee, left)

    {arms, left} =
      seq(
        arms,
        left,
        fn {p, body}, left ->
          {p, left} = pat(p, left)
          {body, left} = expr(body, left)
          {{p, body}, left}
        end,
        {{:pvar, @elided}, elided()}
      )

    {[scrutinee, arms], left}
  end

  defp args(:if, [c, t, e], left) do
    {c, left} = expr(c, left)
    {t, left} = expr(t, left)
    {e, left} = expr(e, left)
    {[c, t, e], left}
  end

  defp args(:fn, [params, body], left) do
    {params, left} =
      seq(
        params,
        left,
        fn {n, t}, left ->
          {t, left} = ty(t, left)
          {{short(n), t}, left}
        end,
        {@elided, {:named, @elided}}
      )

    {body, left} = expr(body, left)
    {[params, body], left}
  end

  defp args(:block, [stmts, last], left) do
    {stmts, left} =
      seq(
        stmts,
        left,
        fn
          {:bind, n, e}, left ->
            {e, left} = expr(e, left)
            {{:bind, short(n), e}, left}

          {:expr, e}, left ->
            {e, left} = expr(e, left)
            {{:expr, e}, left}
        end,
        {:expr, elided()}
      )

    {last, left} = expr(last, left)
    {[stmts, last], left}
  end

  defp args(:jsx, [tag, attrs, children], left) do
    {attrs, left} =
      seq(
        attrs,
        left,
        fn
          {:text, n, text}, left -> {{:text, short(n), short(text)}, max(left - 1, 0)}
          {:expr, n, e}, left -> with_expr(:expr, n, e, left)
          {:event, n, e}, left -> with_expr(:event, n, e, left)
        end,
        {:text, @elided, ""}
      )

    {children, left} =
      seq(
        children,
        left,
        fn
          {:text, text}, left ->
            {{:text, short(text)}, max(left - 1, 0)}

          {:expr, e}, left ->
            {e, left} = expr(e, left)
            {{:expr, e}, left}

          {:element, {:jsx, m, a}}, left ->
            {a, left} = args(:jsx, a, max(left - 1, 0))
            {{:element, {:jsx, strip_meta(m), a}}, left}
        end,
        {:text, @elided}
      )

    {[short(tag), attrs, children], left}
  end

  defp args(:annot, [x, t], left) do
    {x, left} = expr(x, left)
    {t, left} = ty(t, left)
    {[x, t], left}
  end

  defp with_expr(kind, n, e, left) do
    {e, left} = expr(e, left)
    {{kind, short(n), e}, left}
  end

  defp pats(ps, left), do: seq(ps, left, &pat/2, {:pvar, @elided})

  defp pat(_p, 0), do: {{:pvar, @elided}, 0}
  defp pat(:wild, left), do: {:wild, left - 1}
  defp pat({:pvar, n}, left), do: {{:pvar, short(n)}, left - 1}
  defp pat({:pstr, s}, left), do: {{:pstr, short(s)}, left - 1}
  defp pat({k, _} = p, left) when k in [:pint, :pbool], do: {p, left - 1}

  defp pat({:pvariant, n, args}, left) do
    {args, left} = pats(args, left - 1)
    {{:pvariant, short(n), args}, left}
  end

  defp pat({:ptuple, items}, left) do
    {items, left} = pats(items, left - 1)
    {{:ptuple, items}, left}
  end

  defp types(ts, left), do: seq(ts, left, &ty/2, {:named, @elided})

  defp ty(_t, 0), do: {{:named, @elided}, 0}
  defp ty({:named, n}, left), do: {{:named, short(n)}, left - 1}
  defp ty({:var, n}, left), do: {{:var, short(n)}, left - 1}

  defp ty({:applied, n, args}, left) do
    {args, left} = types(args, left - 1)
    {{:applied, short(n), args}, left}
  end

  defp ty({:arrow, ps, ret}, left) do
    {ps, left} = types(ps, left - 1)
    {ret, left} = ty(ret, left)
    {{:arrow, ps, ret}, left}
  end

  defp ty({:tuple, items}, left) do
    {items, left} = types(items, left - 1)
    {{:tuple, items}, left}
  end
end
