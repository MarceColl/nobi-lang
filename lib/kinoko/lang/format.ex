defmodule Kinoko.Lang.Format do
  @moduledoc """
  The syntax tree back to canonical source text (ported from `syntax/format.rs`).

  `Parser.program(Format.program(p)) == p` (modulo meta) for every tree the
  parser builds. Inline or multiline is a style choice; both spellings reparse
  to the same tree.

  A `:field` of a capitalised name (`(M).x`) keeps its parentheses: without
  them `M.x` reads back as the one dotted name `M.x`.

  Every branch, arm, body and element child is formatted once, at the deeper
  indent its multiline spelling needs. A result holding no newline embeds no
  indent, so it is exactly what the shallower indent would have produced and is
  reused verbatim for the inline spelling (formatting twice is exponential in
  depth).
  """

  alias Kinoko.Lang.Ast

  @unary Ast.unary_precedence()
  @postfix @unary + 1
  @atom @postfix + 1
  @inline_width 90
  @indent "  "
  @ops Map.new(Ast.ops(), fn {atom, sym, prec} -> {atom, {sym, prec}} end)

  @doc "Declarations joined by a blank line (no trailing newline)."
  @spec program([Ast.decl()]) :: String.t()
  def program(decls) do
    decls |> Enum.map(&decl/1) |> Enum.intersperse("\n\n") |> IO.iodata_to_binary()
  end

  @spec decl(Ast.decl()) :: String.t()
  def decl({:defapp, _, [name]}), do: "defapp #{name}"

  def decl({:defmodel, _, [name, fields]}) do
    lines =
      Enum.map_join(fields, "\n", fn {f, t, d} ->
        "#{@indent}#{f} : #{type(t)}#{default(d, @indent)}"
      end)

    "defmodel #{name} do\n#{lines}\nend"
  end

  def decl({:deftype, _, [name, params, variants]}) do
    ps = if params == [], do: "", else: "<#{Enum.join(params, ", ")}>"

    vs =
      Enum.map_join(variants, " | ", fn
        {v, []} -> v
        {v, args} -> "#{v}(#{types(args)})"
      end)

    "deftype #{name}#{ps} do\n#{@indent}#{vs}\nend"
  end

  def decl({:def, _, [name, ps, ret, body]}) do
    "def #{name}(#{params(ps)}) : #{type(ret)} do\n#{block_lines(body, @indent)}\nend"
  end

  def decl({:defroutes, _, [name, routes]}) do
    lines =
      Enum.map(routes, fn {segs, app} ->
        "#{@indent}#{quote_str(route_pattern(segs))} -> #{app}\n"
      end)

    "defroutes #{name} do\n#{lines}end"
  end

  def decl({:deftest, _, [name, body]}) do
    "deftest #{name} do\n#{block_lines(body, @indent)}\nend"
  end

  # A model field's default, ` = <constant>`, or nothing.
  defp default(:none, _ind), do: ""
  defp default(d, ind), do: " = " <> fmt(d, 1, ind)

  @spec expr(Ast.node_()) :: String.t()
  def expr(e), do: fmt(e, 1, "")

  @spec type(Ast.type()) :: String.t()
  def type({:named, n}), do: n
  def type({:var, n}), do: n
  def type({:applied, n, args}), do: "#{n}<#{types(args)}>"
  def type({:arrow, [], ret}), do: "(() -> #{type(ret)})"
  def type({:arrow, ps, ret}), do: "(#{types(ps)} -> #{type(ret)})"
  def type({:tuple, items}), do: "(#{types(items)})"

  @doc """
  A signature (`Kinoko.Lang.Types.Extract.signature/1`) of the declaration
  `name`, as one line: a def as `Name(T1, T2) : Ret`; a model as
  `model {f : T, g : U = <default>, ...}`; a type as `type Name<P> = V(T) | W`; a route table as
  `routes {"/" -> App, ...}`; apps and tests
  as `app` / `test`.
  """
  @spec signature(String.t(), term()) :: String.t()
  def signature(name, {:def, params, ret, _names}), do: "#{name}(#{types(params)}) : #{type(ret)}"

  def signature(_, {:model, fields}),
    do:
      "model {" <>
        Enum.map_join(fields, ", ", fn {f, t, d} -> "#{f} : #{type(t)}#{default(d, "")}" end) <>
        "}"

  def signature(name, {:type, params, variants}) do
    head = if params == [], do: name, else: "#{name}<#{Enum.join(params, ", ")}>"

    "type #{head} = " <>
      Enum.map_join(variants, " | ", fn
        {v, []} -> v
        {v, ts} -> "#{v}(#{types(ts)})"
      end)
  end

  def signature(_, {:routes, routes}),
    do:
      "routes {" <>
        Enum.map_join(routes, ", ", fn {segs, app} ->
          "#{quote_str(route_pattern(segs))} -> #{app}"
        end) <>
        "}"

  def signature(_, :app), do: "app"
  def signature(_, :test), do: "test"

  @doc "A route's segments as the pattern written: `[]` is `/`."
  @spec route_pattern([Ast.segment()]) :: String.t()
  def route_pattern(segs) do
    "/" <>
      Enum.map_join(segs, "/", fn
        {:lit, s} -> s
        {:param, n} -> ":" <> n
      end)
  end

  @spec pattern(term) :: String.t()
  def pattern(:wild), do: "_"
  def pattern({:pvar, n}), do: n
  def pattern({:pint, i}), do: Integer.to_string(i)
  def pattern({:pstr, s}), do: quote_str(s)
  def pattern({:pbool, b}), do: to_string(b)
  def pattern({:pvariant, n, []}), do: n
  def pattern({:pvariant, n, args}), do: "#{n}(#{patterns(args)})"
  def pattern({:ptuple, items}), do: "(#{patterns(items)})"

  defp patterns(ps), do: Enum.map_join(ps, ", ", &pattern/1)
  defp types(ts), do: Enum.map_join(ts, ", ", &type/1)
  defp params(ps), do: Enum.map_join(ps, ", ", fn {n, t} -> "#{n} : #{type(t)}" end)

  # A string literal: the exact inverse of the lexer's escapes.
  defp quote_str(s) do
    body =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")
      |> String.replace("\r", "\\r")

    "\"" <> body <> "\""
  end

  # Whether `s` may stand on one line at indent `ind`; width counts
  # codepoints, as the Rust does.
  defp inline?(s, ind) do
    not String.contains?(s, "\n") and
      byte_size(ind) + length(String.to_charlist(s)) <= @inline_width
  end

  defp precedence({:bin, _, [op, _, _]}), do: elem(Map.fetch!(@ops, op), 1)
  defp precedence({k, _, _}) when k in [:not, :neg], do: @unary
  defp precedence({:field, _, _}), do: @postfix
  defp precedence(_), do: @atom

  defp fmt(e, ctx, ind) do
    raw = raw(e, ind)
    if precedence(e) < ctx, do: "(" <> raw <> ")", else: raw
  end

  defp exprs(es, ind), do: Enum.map_join(es, ", ", &fmt(&1, 1, ind))

  defp field_inits(fs, ind),
    do: Enum.map_join(fs, ", ", fn {n, e} -> "#{n}: #{fmt(e, 1, ind)}" end)

  defp stmt({:bind, n, e}, ind), do: "#{n} = #{fmt(e, 1, ind)}"
  defp stmt({:expr, e}, ind), do: fmt(e, 1, ind)

  defp block_lines({:block, _, [stmts, last]}, ind) do
    stmts
    |> Enum.map(&(ind <> stmt(&1, ind)))
    |> Kernel.++([ind <> fmt(last, 1, ind)])
    |> Enum.join("\n")
  end

  defp branch({:block, _, _} = b, ind), do: block_lines(b, ind)
  defp branch(e, ind), do: ind <> fmt(e, 1, ind)

  defp raw({:int, _, [n]}, _), do: Integer.to_string(n)
  defp raw({:str, _, [s]}, _), do: quote_str(s)
  defp raw({:bool, _, [b]}, _), do: to_string(b)
  defp raw({:name, _, [n]}, _), do: n
  defp raw({:list, _, items}, ind), do: "[#{exprs(items, ind)}]"

  defp raw({:map, _, entries}, ind) do
    es = Enum.map_join(entries, ", ", fn {k, v} -> "#{fmt(k, 1, ind)} => #{fmt(v, 1, ind)}" end)
    "%{" <> es <> "}"
  end

  defp raw({:tuple, _, items}, ind), do: "(#{exprs(items, ind)})"

  defp raw({:bin, _, [op, l, r]}, ind) do
    {sym, p} = Map.fetch!(@ops, op)
    "#{fmt(l, p, ind)} #{sym} #{fmt(r, p + 1, ind)}"
  end

  defp raw({:not, _, [x]}, ind), do: "not " <> fmt(x, @unary + 1, ind)
  defp raw({:neg, _, [x]}, ind), do: "-" <> fmt(x, @unary + 1, ind)
  defp raw({:call, _, [n, args]}, ind), do: "#{n}(#{exprs(args, ind)})"

  defp raw({:field, _, [{:name, _, [n]}, f]}, _ind) do
    if Ast.capitalised?(n), do: "(#{n}).#{f}", else: "#{n}.#{f}"
  end

  defp raw({:field, _, [obj, f]}, ind), do: "#{fmt(obj, @postfix, ind)}.#{f}"
  defp raw({:construct, _, [model, fs]}, ind), do: "%#{model}{#{field_inits(fs, ind)}}"

  defp raw({:update, _, [model, base, fs]}, ind),
    do: "%#{model}{#{fmt(base, 1, ind)} | #{field_inits(fs, ind)}}"

  defp raw({:always, _, [x]}, ind), do: "always(#{fmt(x, 1, ind)})"
  defp raw({:sometimes, _, [x]}, ind), do: "sometimes(#{fmt(x, 1, ind)})"

  defp raw({:block, _, _} = b, ind),
    do: "do\n#{block_lines(b, ind <> @indent)}\n#{ind}end"

  defp raw({:if, _, [cond_, then, otherwise]}, ind) do
    c = fmt(cond_, 1, ind)
    inner = ind <> @indent
    then_s = branch(then, inner)
    else_s = branch(otherwise, inner)
    blocks? = match?({:block, _, _}, then) or match?({:block, _, _}, otherwise)

    inline =
      if not blocks? and not String.contains?(then_s, "\n") and
           not String.contains?(else_s, "\n") do
        s = "if #{c} do #{drop(then_s, inner)} else #{drop(else_s, inner)} end"
        if inline?(s, ind), do: s
      end

    inline || "if #{c} do\n#{then_s}\n#{ind}else\n#{else_s}\n#{ind}end"
  end

  defp raw({:case, _, [scrutinee, arms]}, ind) do
    inner = ind <> @indent
    deeper = inner <> @indent

    arms_s =
      Enum.map_join(arms, "\n", fn {pat, body} ->
        p = pattern(pat)
        b = fmt(body, 1, deeper)

        if not String.contains?(b, "\n") and inline?("#{p} -> #{b}", inner),
          do: "#{inner}#{p} -> #{b}",
          else: "#{inner}#{p} ->\n#{deeper}#{b}"
      end)

    "case #{fmt(scrutinee, 1, ind)} do\n#{arms_s}\n#{ind}end"
  end

  defp raw({:fn, _, [ps, body]}, ind) do
    ps_s = params(ps)
    inner = ind <> @indent
    body_s = branch(body, inner)

    inline =
      if not match?({:block, _, _}, body) and not String.contains?(body_s, "\n") do
        s = "fn (#{ps_s}) -> #{drop(body_s, inner)} end"
        if inline?(s, ind), do: s
      end

    inline || "fn (#{ps_s}) ->\n#{body_s}\n#{ind}end"
  end

  defp raw({:jsx, _, _} = j, ind), do: jsx(j, ind)
  defp raw({:annot, _, [x, t]}, ind), do: "(#{fmt(x, 1, ind)} : #{type(t)})"

  defp drop(s, prefix), do: binary_part(s, byte_size(prefix), byte_size(s) - byte_size(prefix))

  defp attr({:text, n, text}, _), do: "#{n}=#{quote_str(text)}"
  defp attr({:expr, n, e}, ind), do: "#{n}={#{fmt(e, 1, ind)}}"
  defp attr({:event, n, e}, ind), do: "on-#{n}={#{fmt(e, 1, ind)}}"

  # An element on one line when it has no element child and fits, otherwise one
  # child per line. Each child is formatted once, at the children's indent.
  defp jsx({:jsx, _, [tag, attrs, children]}, ind) do
    attrs_s = Enum.map_join(attrs, "", &(" " <> attr(&1, ind)))

    if children == [] do
      "<#{tag}#{attrs_s} />"
    else
      inner = ind <> @indent

      cs =
        Enum.map(children, fn
          {:text, text} -> text
          {:expr, e} -> "{" <> fmt(e, 1, inner) <> "}"
          {:element, j} -> jsx(j, inner)
        end)

      has_element? = Enum.any?(children, &match?({:element, _}, &1))

      inline =
        if not has_element? and Enum.all?(cs, &(not String.contains?(&1, "\n"))) do
          s = "<#{tag}#{attrs_s}>#{Enum.join(cs)}</#{tag}>"
          if inline?(s, ind), do: s
        end

      inline ||
        "<#{tag}#{attrs_s}>\n#{Enum.map_join(cs, "\n", &(inner <> &1))}\n#{ind}</#{tag}>"
    end
  end
end
