defmodule Kinoko.Lang.Parser do
  @moduledoc """
  Source text to the Yabu AST (port of `syntax/parser.rs`): recursive descent,
  with precedence climbing for binary operators.

  Newlines separate the statements of a block, so they are significant
  everywhere except where a production skips them explicitly: between
  declarations, statements, model fields, case arms and a deftype's `|`
  variants; inside parameter, argument, list and map-entry brackets, record
  field-init lists and tuples; after a binary operator, a binding's `=`, a case
  arm's `->` and an update's `|`.

  Every construct that closes with `end` pushes an opener when it opens and
  pops it at its `end`, so a missing `end` is blamed on the construct still open.

  `<` starts a JSX element only where an operand is expected (`primary/1`).
  Inside an element the lexer runs in raw mode; the parser's `cur` is then
  `:raw` and `lx` is the raw cursor. The parser carries the immutable
  `Kinoko.Lang.Lexer` cursor, with one token of lookahead (`cur`) and the
  cursor positioned just after it.

  Nodes are `{kind, [line:, col:], args}` (see `Kinoko.Lang.Ast`). `:list`,
  `:map` and `:tuple` expressions carry their items directly as `args`.
  Parse errors are `%{code: "parse", message:, line:, col:}`.

  Nesting (and the length of an operator or field chain, which nests the tree
  once per link) is bounded by `max_depth/0`; deeper input is a parse error.
  """

  alias Kinoko.Lang.{Ast, Format, Lexer}

  @max_depth 512

  @decl_kw ~w(def defmodel deftype defapp deftest defroutes)
  @keywords ~w(def defmodel deftype defapp deftest defroutes do end case if else fn always sometimes and or not true false)

  @binops Map.new(Ast.ops(), fn {atom, sym, prec} -> {sym, {atom, prec}} end)

  @puncts %{
    lparen: "(",
    rparen: ")",
    lbracket: "[",
    rbracket: "]",
    lbrace: "{",
    rbrace: "}",
    arrow: "->",
    fat_arrow: "=>",
    eq: "=",
    colon: ":",
    comma: ",",
    dot: ".",
    pipe: "|",
    percent: "%"
  }

  @type error :: %{code: String.t(), message: String.t(), line: pos_integer, col: pos_integer}

  @doc "The deepest nesting a parse accepts."
  @spec max_depth() :: 512
  def max_depth, do: @max_depth

  @doc "Parse a whole program into declarations."
  @spec program(String.t()) :: {:ok, [Ast.decl()]} | {:error, error}
  def program(src), do: run(src, &program_body/1)

  @doc "Parse a single expression."
  @spec expr(String.t()) :: {:ok, Ast.node_()} | {:error, error}
  def expr(src), do: run(src, &expr_top/1)

  defp run(src, f) when is_binary(src) do
    if String.valid?(src) do
      try do
        {:ok, src |> init() |> f.()}
      catch
        {:perr, line, col, msg} -> {:error, %{code: "parse", message: msg, line: line, col: col}}
      end
    else
      {:error, %{code: "parse", message: "source is not valid UTF-8", line: 1, col: 1}}
    end
  end

  defp init(src), do: advance(%{cur: nil, lx: Lexer.new(src), openers: [], depth: 0, reach: 0})

  # ---------- tokens ----------

  # Lex the token after the cursor into `cur`. A lex error is held in `cur`
  # and raised only when that token is looked at.
  defp advance(%{lx: lx} = p) do
    case Lexer.next_token(lx) do
      {:ok, tok, lx} -> %{p | cur: tok, lx: lx}
      {:error, e} -> %{p | cur: {:lexerr, e}}
    end
  end

  defp peek(%{cur: {:lexerr, e}}), do: throw_lex(e)

  defp peek(%{cur: :raw}),
    do: throw({:perr, 1, 1, "internal: the parser looked at a token inside JSX"})

  defp peek(%{cur: tok}), do: tok

  defp next(p) do
    tok = peek(p)
    {tok, advance(p)}
  end

  # The token after `cur`.
  defp peek2(p) do
    peek(p)

    case Lexer.next_token(p.lx) do
      {:ok, tok, _} -> tok
      {:error, e} -> throw_lex(e)
    end
  end

  defp throw_lex(e), do: throw({:perr, e.line, e.col, e.message})

  defp err_at(tok, msg), do: throw({:perr, elem(tok, 2), elem(tok, 3), msg})
  defp err_pos(line, col, msg), do: throw({:perr, line, col, msg})

  defp error_here(%{cur: :raw, lx: lx}, msg) do
    {l, c} = Lexer.position(lx)
    err_pos(l, c, msg)
  end

  defp error_here(p, msg), do: err_at(peek(p), msg)

  defp meta(tok), do: [line: elem(tok, 2), col: elem(tok, 3)]

  defp spec?({:op, s}, {:op, s, _, _}), do: true
  defp spec?(kind, tok) when is_atom(kind), do: elem(tok, 0) == kind
  defp spec?(_, _), do: false

  defp at?(p, spec), do: spec?(spec, peek(p))

  defp at_kw?(p, word) do
    case peek(p) do
      {:name, ^word, _, _} -> true
      _ -> false
    end
  end

  defp sym({:op, s}), do: s
  defp sym(kind), do: Map.fetch!(@puncts, kind)

  defp describe({:name, s, _, _}), do: s
  defp describe({:int, n, _, _}), do: Integer.to_string(n)
  defp describe({:str, s, _, _}), do: "\"#{s}\""
  defp describe({:op, s, _, _}), do: s
  defp describe({:newline, _, _, _}), do: "newline"
  defp describe({:eof, _, _, _}), do: "eof"
  defp describe({kind, _, _, _}), do: Map.fetch!(@puncts, kind)

  defp skip_nl(p) do
    case peek(p) do
      {:newline, _, _, _} -> p |> advance() |> skip_nl()
      _ -> p
    end
  end

  defp expect(p, spec) do
    {t, p} = next(p)

    if spec?(spec, t) do
      {t, p}
    else
      err_at(t, "expected '#{sym(spec)}', got '#{describe(t)}'")
    end
  end

  defp expect_keyword(p, word) do
    {t, p} = next(p)

    case t do
      {:name, ^word, _, _} -> {t, p}
      _ -> err_at(t, "expected '#{word}', got '#{describe(t)}'")
    end
  end

  defp expect_word(p) do
    {t, p} = next(p)

    case t do
      {:name, w, _, _} ->
        if w in @keywords,
          do: err_at(t, "'#{w}' is a keyword and cannot be used as a name"),
          else: {w, p}

      _ ->
        err_at(t, "expected a name, got '#{describe(t)}'")
    end
  end

  # ---------- open constructs and depth ----------

  defp open_do(p) do
    {t, p} = expect_keyword(p, "do")
    {t, %{p | openers: [{"do", elem(t, 2), elem(t, 3)} | p.openers]}}
  end

  defp close_end(p) do
    {t, p} = expect_keyword(p, "end")
    {t, %{p | openers: tl(p.openers)}}
  end

  defp unclosed(p, tok, saw) do
    case p.openers do
      [] ->
        err_at(tok, "unexpected #{saw}")

      [{what, l, c} | _] ->
        err_at(tok, "unclosed `#{what}` opened at #{l}:#{c} — expected `end` before #{saw}")
    end
  end

  # Whether one of `terms` is next. End of input or a declaration keyword
  # instead means the open construct was never closed.
  defp at_terminator?(p, terms) do
    t = peek(p)

    case t do
      {:eof, _, _, _} ->
        unclosed(p, t, "end of input")

      {:name, w, _, _} ->
        cond do
          w in terms -> true
          w in @decl_kw -> unclosed(p, t, "`#{w}`")
          true -> false
        end

      _ ->
        false
    end
  end

  # Every seam that recurses goes through here, so nesting is a diagnostic,
  # not a crash.
  defp nested(p, f) do
    if p.depth >= @max_depth, do: error_here(p, "nesting too deep (limit #{@max_depth})")
    depth = p.depth + 1
    {v, p2} = f.(%{p | depth: depth, reach: max(p.reach, depth)})
    {v, %{p2 | depth: p.depth}}
  end

  # A left-associative chain nests the tree once per link while its loop stays
  # flat, so `nested` never sees it: measure `reach` afresh from here.
  defp chain(p, f) do
    {v, p2} = f.(%{p | reach: p.depth})
    {v, %{p2 | reach: max(p2.reach, p.reach)}}
  end

  defp link(p, at) do
    reach = p.reach + 1

    if reach >= @max_depth,
      do: err_at(at, "expression too deep (limit #{@max_depth})"),
      else: %{p | reach: reach}
  end

  # ---------- lists ----------

  # Items up to `close`, which it consumes; commas between them are optional
  # and newlines are ignored. The opener is already consumed.
  defp loose_list(p, close, item), do: p |> skip_nl() |> loose_loop(close, item, [])

  defp loose_loop(p, close, item, acc) do
    if at?(p, close) do
      {Enum.reverse(acc), advance(p)}
    else
      {v, p} = item.(p)
      p = skip_nl(p)

      p =
        if at?(p, :comma), do: p |> advance() |> skip_nl(), else: p

      loose_loop(p, close, item, [v | acc])
    end
  end

  # `open item, item close` if `open` is next: one or more items, commas
  # required, newlines significant. `nil` when `open` is not next.
  defp tight_list(p, open, close, item) do
    if at?(p, open) do
      {first, p} = p |> advance() |> item.()
      tight_loop(p, close, item, [first])
    else
      {nil, p}
    end
  end

  defp tight_loop(p, close, item, acc) do
    if at?(p, :comma) do
      {v, p} = p |> advance() |> item.()
      tight_loop(p, close, item, [v | acc])
    else
      {_, p} = expect(p, close)
      {Enum.reverse(acc), p}
    end
  end

  # ---------- program and declarations ----------

  defp expr_top(p) do
    p = skip_nl(p)
    {e, p} = exp(p)
    p = skip_nl(p)
    t = peek(p)

    case t do
      {:eof, _, _, _} -> e
      _ -> err_at(t, "unexpected '#{describe(t)}' after expression")
    end
  end

  defp program_body(p), do: p |> skip_nl() |> decls([])

  defp decls(p, acc) do
    case peek(p) do
      {:eof, _, _, _} ->
        Enum.reverse(acc)

      _ ->
        {d, p} = decl(p)
        decls(skip_nl(p), [d | acc])
    end
  end

  defp decl(p) do
    {t, p} = next(p)
    m = meta(t)

    case t do
      {:name, "def", _, _} ->
        {name, p} = qualified_name(p)
        {params, p} = params(p)
        {_, p} = expect(p, :colon)
        {ret, p} = ty(p)
        {open, p} = open_do(p)
        {stmts, last, p} = rest_of_block(p)
        {{:def, m, [name, params, ret, {:block, meta(open), [stmts, last]}]}, p}

      {:name, "defmodel", _, _} ->
        defmodel(p, m)

      {:name, "deftype", _, _} ->
        deftype(p, m)

      {:name, "defapp", _, _} ->
        {name, p} = qualified_name(p)
        {{:defapp, m, [name]}, p}

      {:name, "deftest", _, _} ->
        {name, p} = qualified_name(p)
        {open, p} = open_do(p)
        {stmts, last, p} = rest_of_block(p)
        {{:deftest, m, [name, {:block, meta(open), [stmts, last]}]}, p}

      {:name, "defroutes", _, _} ->
        defroutes(p, m)

      {:name, w, _, _} ->
        err_at(
          t,
          "expected 'def', 'defmodel', 'deftype', 'defapp', 'deftest' or 'defroutes', got '#{w}'"
        )

      _ ->
        err_at(t, "expected a declaration, got '#{describe(t)}'")
    end
  end

  # `Counter.Msg.Add`, `total`: names joined by dots, of any case.
  defp qualified_name(p) do
    {w, p} = expect_word(p)
    qualified_rest(p, w)
  end

  defp qualified_rest(p, acc) do
    if at?(p, :dot) and match?({:name, _, _, _}, peek2(p)) do
      {w, p} = p |> advance() |> expect_word()
      qualified_rest(p, acc <> "." <> w)
    else
      {acc, p}
    end
  end

  defp params(p) do
    {_, p} = expect(p, :lparen)
    loose_list(p, :rparen, &typed_name/1)
  end

  # `name : Type`, a parameter or a model field.
  defp typed_name(p) do
    {name, p} = expect_word(p)
    {_, p} = expect(p, :colon)
    {t, p} = ty(p)
    {{name, t}, p}
  end

  defp defmodel(p, m) do
    {name, p} = qualified_name(p)
    {_, p} = open_do(p)
    p = skip_nl(p)
    {fields, p} = model_fields(p, [])
    {_, p} = close_end(p)
    {{:defmodel, m, [name, fields]}, p}
  end

  defp model_fields(p, acc) do
    if at_terminator?(p, ["end"]) do
      {Enum.reverse(acc), p}
    else
      {f, p} = typed_name(p)
      model_fields(skip_nl(p), [f | acc])
    end
  end

  # `defroutes Name do "/pattern" -> App ... end`: each pattern parsed here
  # into its segments, so a malformed one is an error at the pattern.
  defp defroutes(p, m) do
    {name, p} = qualified_name(p)
    {_, p} = open_do(p)
    p = skip_nl(p)
    {routes, p} = routes(p, [])
    {_, p} = close_end(p)
    {{:defroutes, m, [name, routes]}, p}
  end

  defp routes(p, acc) do
    if at_terminator?(p, ["end"]) do
      {Enum.reverse(acc), p}
    else
      {r, p} = route(p)
      routes(skip_nl(p), [r | acc])
    end
  end

  defp route(p) do
    {t, p} = next(p)

    pattern =
      case t do
        {:str, s, _, _} -> s
        _ -> err_at(t, ~s(expected a route `"/path" -> App`, got '#{describe(t)}'))
      end

    segments =
      case route_segments(pattern) do
        {:ok, segments} -> segments
        {:error, why} -> err_at(t, ~s(route pattern #{inspect(pattern)} #{why}))
      end

    {_, p} = expect(p, :arrow)
    target_tok = peek(p)
    {target, p} = qualified_name(p)

    unless Ast.capitalised?(target),
      do: err_at(target_tok, "route target `#{target}` must be an app's name, as in `Forum.Post`")

    {{segments, target}, p}
  end

  @doc """
  A route pattern's segments: `"/"` is `[]`, `"/post/:id"` is
  `[{:lit, "post"}, {:param, "id"}]`. `{:error, why}` for a malformed one.
  """
  @spec route_segments(String.t()) ::
          {:ok, [{:lit, String.t()} | {:param, String.t()}]} | {:error, String.t()}
  def route_segments("/"), do: {:ok, []}

  def route_segments("/" <> rest = pattern) do
    rest
    |> String.split("/")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case route_segment(part, pattern) do
        {:ok, seg} -> {:cont, {:ok, [seg | acc]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, segs} -> repeated_param(Enum.reverse(segs))
      e -> e
    end
  end

  def route_segments(pattern),
    do: {:error, ~s(must start with `/` — write it as "/#{pattern}")}

  defp route_segment("", _),
    do: {:error, ~s(has an empty segment — write "/a/b", never "/a//b" or "/a/")}

  defp route_segment(":", _),
    do: {:error, "has a `:` with no parameter name — write `:id`"}

  defp route_segment(":" <> name, _) do
    if Regex.match?(~r/\A[a-z_][A-Za-z0-9_]*\z/, name),
      do: {:ok, {:param, name}},
      else:
        {:error,
         "has parameter `#{name}` — a parameter is a lowercase identifier, as in `:id` or `:post_id`"}
  end

  defp route_segment(part, _) do
    cond do
      String.contains?(part, ":") ->
        {:error,
         "has `:` inside segment #{inspect(part)} — a parameter is a whole segment, as in \"/post/:id\""}

      part in [".", ".."] ->
        {:error, "has segment #{inspect(part)} — `.` and `..` are not route segments"}

      Regex.match?(~r/\A[A-Za-z0-9_.~-]+\z/, part) ->
        {:ok, {:lit, part}}

      true ->
        {:error,
         "has segment #{inspect(part)} — a literal segment holds only letters, digits, `-`, `_`, `.` and `~`"}
    end
  end

  defp repeated_param(segs) do
    names = for {:param, n} <- segs, do: n

    case names -- Enum.uniq(names) do
      [] -> {:ok, segs}
      [n | _] -> {:error, "names parameter `#{n}` twice — each parameter is named once"}
    end
  end

  defp deftype(p, m) do
    {name, p} = qualified_name(p)
    {tparams, p} = tight_list(p, {:op, "<"}, {:op, ">"}, &expect_word/1)
    {_, p} = open_do(p)
    p = skip_nl(p)
    {first, p} = variant(p)
    {variants, p} = variants(p, [first])
    at_terminator?(p, ["end"])
    {_, p} = close_end(p)
    {{:deftype, m, [name, tparams || [], variants]}, p}
  end

  defp variants(p, acc) do
    p = skip_nl(p)

    if at?(p, :pipe) do
      {v, p} = p |> advance() |> skip_nl() |> variant()
      variants(p, [v | acc])
    else
      {Enum.reverse(acc), p}
    end
  end

  defp variant(p) do
    {name, p} = expect_word(p)
    {args, p} = tight_list(p, :lparen, :rparen, &ty/1)
    {{name, args || []}, p}
  end

  # ---------- types ----------

  defp ty(p), do: nested(p, &ty_inner/1)

  defp ty_inner(p) do
    if at?(p, :lparen) do
      p = p |> advance() |> skip_nl()
      {first, p} = ty(p)
      {items, p} = ty_items(p, [first])

      if at?(p, :arrow) do
        {ret, p} = p |> advance() |> ty()
        {_, p} = expect(p, :rparen)
        {{:arrow, items, ret}, p}
      else
        {_, p} = expect(p, :rparen)

        case items do
          [one] -> {one, p}
          _ -> {{:tuple, items}, p}
        end
      end
    else
      {name, p} = qualified_name(p)

      case tight_list(p, {:op, "<"}, {:op, ">"}, &ty/1) do
        {nil, p} -> {{:named, name}, p}
        {args, p} -> {{:applied, name, args}, p}
      end
    end
  end

  defp ty_items(p, acc) do
    if at?(p, :comma) do
      {t, p} = p |> advance() |> skip_nl() |> ty()
      ty_items(p, [t | acc])
    else
      {Enum.reverse(acc), p}
    end
  end

  # ---------- statements ----------

  # Newline-separated statements up to one of `terms`, which is left for the caller.
  defp stmts(p, terms, acc \\ []) do
    p = skip_nl(p)

    if at_terminator?(p, terms) do
      {Enum.reverse(acc), p}
    else
      {s, p} = stmt(p)

      cond do
        at?(p, :newline) ->
          stmts(p, terms, [s | acc])

        at_terminator?(p, terms) ->
          {Enum.reverse([s | acc]), p}

        true ->
          t = peek(p)
          err_at(t, "expected a newline or '#{hd(terms)}', got '#{describe(t)}'")
      end
    end
  end

  # The statements of an opened block, through its `end`: `{stmts, last, p}`.
  defp rest_of_block(p) do
    {stmts, p} = stmts(p, ["end"])
    {end_tok, p} = close_end(p)
    {stmts, last} = into_block(stmts, end_tok)
    {stmts, last, p}
  end

  defp into_block(stmts, end_tok) do
    case Enum.reverse(stmts) do
      [{:expr, last} | rest] ->
        {Enum.reverse(rest), last}

      [{:bind, name, _} | _] ->
        err_at(end_tok, "a block cannot end with a binding: `#{name} = …`")

      [] ->
        err_at(end_tok, "a block needs an expression before `#{describe(end_tok)}`")
    end
  end

  # A one-statement block is its expression; only `def` and `deftest` bodies
  # stay a block whatever they hold.
  defp collapse(_m, [], last), do: last
  defp collapse(m, stmts, last), do: {:block, m, [stmts, last]}

  defp stmt(p) do
    case peek(p) do
      {:name, w, _, _} when w not in @keywords ->
        if match?({:eq, _, _, _}, peek2(p)) do
          p = p |> advance() |> advance() |> skip_nl()
          {e, p} = exp(p)
          {{:bind, w, e}, p}
        else
          expr_stmt(p)
        end

      _ ->
        expr_stmt(p)
    end
  end

  defp expr_stmt(p) do
    {e, p} = exp(p)

    # Only a `case` takes a tuple apart, by design: say where to.
    if match?({:tuple, _, _}, e) and at?(p, :eq) do
      error_here(
        p,
        "a binding names one value — take a tuple apart with `case p do (a, b) -> … end`"
      )
    else
      {{:expr, e}, p}
    end
  end

  # ---------- expressions ----------

  defp exp(p), do: nested(p, &binary(&1, 1))

  # Operators binding at least as tightly as `min`, left-associative.
  defp binary(p, min) do
    chain(p, fn p ->
      {left, p} = unary(p)
      bin_loop(p, min, left)
    end)
  end

  defp bin_loop(p, min, left) do
    case binop(peek(p)) do
      {atom, prec} when prec >= min ->
        {at, p} = next(p)
        p = skip_nl(p)
        {right, p} = binary(p, prec + 1)
        p = link(p, at)
        {_, lm, _} = left
        bin_loop(p, min, {:bin, lm, [atom, left, right]})

      _ ->
        {left, p}
    end
  end

  defp binop({:op, s, _, _}), do: Map.get(@binops, s)
  defp binop({:name, s, _, _}) when s in ["and", "or"], do: Map.get(@binops, s)
  defp binop(_), do: nil

  defp unary(p) do
    t = peek(p)

    cond do
      match?({:name, "not", _, _}, t) ->
        {e, p} = p |> advance() |> unary_operand()
        {{:not, meta(t), [e]}, p}

      match?({:op, "-", _, _}, t) ->
        {e, p} = p |> advance() |> unary_operand()
        {{:neg, meta(t), [e]}, p}

      true ->
        postfix(p)
    end
  end

  # Binds tighter than every binary operator.
  defp unary_operand(p), do: nested(p, &binary(&1, Ast.unary_precedence()))

  # Field access on anything, and a call on any name, local or dotted.
  defp postfix(p) do
    chain(p, fn p ->
      {e, p} = primary(p)
      postfix_loop(p, e)
    end)
  end

  defp postfix_loop(p, e) do
    cond do
      at?(p, :dot) and match?({:name, _, _, _}, peek2(p)) ->
        {dot, p} = next(p)
        p = link(p, dot)
        {f, p} = expect_word(p)
        {_, em, _} = e
        postfix_loop(p, {:field, em, [e, f]})

      match?({:name, _, [_]}, e) and at?(p, :lparen) ->
        {:name, em, [name]} = e
        {args, p} = p |> advance() |> loose_list(:rparen, &exp/1)
        postfix_loop(p, {:call, em, [name, args]})

      true ->
        {e, p}
    end
  end

  defp primary(p) do
    t = peek(p)
    m = meta(t)

    case t do
      {:int, n, _, _} ->
        {{:int, m, [n]}, advance(p)}

      {:str, s, _, _} ->
        {{:str, m, [s]}, advance(p)}

      {:name, w, _, _} ->
        word(p, w, t)

      {:lparen, _, _, _} ->
        parens(p)

      {:lbracket, _, _, _} ->
        {items, p} = p |> advance() |> loose_list(:rbracket, &exp/1)
        {{:list, m, items}, p}

      {:percent, _, _, _} ->
        percent(p)

      {:op, "<", _, _} ->
        # The cursor is just past `<`: continue in raw mode.
        {node, p} = jsx_element(%{p | cur: :raw})
        {node, advance(p)}

      {:lbrace, _, _, _} ->
        err_at(
          t,
          "`{` does not start an expression — a model is `%Model{field: value}` and a map is `%{key => value}`"
        )

      {kind, _, _, _} when kind in [:colon, :eq] ->
        err_at(
          t,
          "unexpected '#{describe(t)}' — Yabu has no named arguments; a call is positional and a model is built with `%Model{field: value}`"
        )

      _ ->
        err_at(t, "expected an expression, got '#{describe(t)}'")
    end
  end

  # A primary that starts with the identifier `w` (the token `t`).
  defp word(p, w, t) do
    m = meta(t)

    case w do
      b when b in ["true", "false"] ->
        {{:bool, m, [b == "true"]}, advance(p)}

      "case" ->
        case_expr(p, m)

      "if" ->
        if_expr(p, m)

      "fn" ->
        fn_expr(p, m)

      "do" ->
        {open, p} = open_do(p)
        {stmts, last, p} = rest_of_block(p)
        {collapse(meta(open), stmts, last), p}

      a when a in ["always", "sometimes"] ->
        kind = if a == "always", do: :always, else: :sometimes
        p = advance(p)
        {_, p} = expect(p, :lparen)
        {e, p} = exp(p)
        {_, p} = expect(p, :rparen)
        {{kind, m, [e]}, p}

      _ ->
        cond do
          w in @decl_kw ->
            unclosed(p, t, "`#{w}`")

          w in @keywords ->
            err_at(t, "unexpected keyword '#{w}'")

          Ast.capitalised?(w) ->
            # A capitalised head is a dotted name; a lowercase one is a local,
            # and any dots after it are field access.
            {name, p} = qualified_name(p)

            if at?(p, :lbrace) do
              error_here(p, "`#{name}{…}` needs a leading %: write `%#{name}{field: value}`")
            else
              {{:name, m, [name]}, p}
            end

          true ->
            {{:name, m, [w]}, advance(p)}
        end
    end
  end

  # `(e)` is grouping; `(a, b)` is a tuple; `(e : T)` is an annotation, of the
  # one expression in its parentheses.
  defp parens(p) do
    one_expression =
      "an annotation wraps one expression in parentheses of its own — " <>
        "`((a, b) : (A, B))` annotates a tuple, `((a : A), (b : B))` its items"

    {open, p} = next(p)
    p = skip_nl(p)
    {first, p} = exp(p)
    p = skip_nl(p)

    if at?(p, :colon) do
      p = p |> advance() |> skip_nl()
      {t, p} = ty(p)
      p = skip_nl(p)
      if at?(p, :comma), do: error_here(p, one_expression)
      {_, p} = expect(p, :rparen)
      {{:annot, meta(open), [first, t]}, p}
    else
      {items, p} = paren_items(p, [first])
      if at?(p, :colon), do: error_here(p, one_expression)
      {_, p} = expect(p, :rparen)

      case items do
        [one] -> {one, p}
        _ -> {{:tuple, meta(open), items}, p}
      end
    end
  end

  defp paren_items(p, acc) do
    if at?(p, :comma) do
      {e, p} = p |> advance() |> skip_nl() |> exp()
      paren_items(skip_nl(p), [e | acc])
    else
      {Enum.reverse(acc), p}
    end
  end

  # `%{k => v, …}` is a map; otherwise a qualified name then `{` starts a
  # record. Inside the braces, an identifier immediately followed by `:` picks
  # construct over update.
  defp percent(p) do
    {pct, p} = next(p)
    m = meta(pct)

    if at?(p, :lbrace) do
      p = p |> advance() |> skip_nl()
      {entries, p} = map_entries(p, [])
      {{:map, m, entries}, p}
    else
      {model, p} = qualified_name(p)
      {_, p} = expect(p, :lbrace)
      p = skip_nl(p)

      cond do
        at?(p, :rbrace) ->
          {{:construct, m, [model, []]}, advance(p)}

        match?({:name, _, _, _}, peek(p)) and match?({:colon, _, _, _}, peek2(p)) ->
          {fields, p} = field_inits(p)
          {{:construct, m, [model, fields]}, p}

        true ->
          {base, p} = exp(p)
          p = skip_nl(p)
          {_, p} = expect(p, :pipe)
          p = skip_nl(p)
          {fields, p} = field_inits(p)
          {{:update, m, [model, base, fields]}, p}
      end
    end
  end

  defp map_entries(p, acc) do
    if at?(p, :rbrace) do
      {Enum.reverse(acc), advance(p)}
    else
      {k, p} = exp(p)
      {_, p} = expect(p, :fat_arrow)
      {v, p} = exp(p)
      p = skip_nl(p)
      p = if at?(p, :comma), do: p |> advance() |> skip_nl(), else: p
      map_entries(p, [{k, v} | acc])
    end
  end

  # `name: e, …}`, through the closing `}` it consumes.
  defp field_inits(p, acc \\ []) do
    {name, p} = expect_word(p)
    {_, p} = expect(p, :colon)
    {e, p} = exp(p)
    p = skip_nl(p)
    acc = [{name, e} | acc]

    if at?(p, :comma) do
      p |> advance() |> skip_nl() |> field_inits(acc)
    else
      {_, p} = expect(p, :rbrace)
      {Enum.reverse(acc), p}
    end
  end

  defp case_expr(p, m) do
    p = advance(p)
    {scrutinee, p} = exp(p)
    {_, p} = open_do(p)
    p = skip_nl(p)
    {arms, p} = arms(p, [])
    {_, p} = close_end(p)
    {{:case, m, [scrutinee, arms]}, p}
  end

  defp arms(p, acc) do
    if at_terminator?(p, ["end"]) do
      {Enum.reverse(acc), p}
    else
      {pat, p} = pattern(p)
      {_, p} = expect(p, :arrow)
      p = skip_nl(p)
      {body, p} = exp(p)
      refuse_a_swallowed_arm(p, body)
      arms(skip_nl(p), [{pat, body} | acc])
    end
  end

  # `n (a, b)` on one line is a call, so in a one-line `case` an arm whose body
  # ends in a name takes the next arm's tuple pattern as that call's arguments,
  # and the parse stops at the `->` after it. Say so, naming the call.
  defp refuse_a_swallowed_arm(p, body) do
    with call when call != nil <- trailing_call(body),
         true <- at?(p, :arrow) do
      error_here(
        p,
        "the call `#{Format.expr(call)}` swallowed the next arm's tuple pattern — start each arm on its own line"
      )
    else
      _ -> :ok
    end
  end

  defp trailing_call({:call, _, _} = e), do: e
  defp trailing_call({:bin, _, [_, _, last]}), do: trailing_call(last)
  defp trailing_call({:not, _, [last]}), do: trailing_call(last)
  defp trailing_call({:neg, _, [last]}), do: trailing_call(last)
  defp trailing_call(_), do: nil

  defp pattern(p), do: nested(p, &pattern_inner/1)

  # A pattern. `(p)` is grouping; `(a, b)` is a tuple.
  defp pattern_inner(p) do
    t = peek(p)

    case t do
      {:lparen, _, _, _} ->
        {items, p} = tight_list(p, :lparen, :rparen, &pattern/1)

        case items do
          [one] -> {one, p}
          _ -> {{:ptuple, items}, p}
        end

      {:int, n, _, _} ->
        {{:pint, n}, advance(p)}

      {:str, s, _, _} ->
        {{:pstr, s}, advance(p)}

      {:op, "-", _, _} ->
        case peek2(p) do
          {:int, n, _, _} -> {{:pint, -n}, p |> advance() |> advance()}
          _ -> err_at(t, "expected a pattern, got '-'")
        end

      {:name, w, _, _} ->
        name_pattern(p, w, t)

      _ ->
        err_at(t, "expected a pattern, got '#{describe(t)}'")
    end
  end

  defp name_pattern(p, w, t) do
    cond do
      w in ["true", "false"] ->
        {{:pbool, w == "true"}, advance(p)}

      w == "_" ->
        {:wild, advance(p)}

      w in @keywords ->
        err_at(t, "unexpected keyword '#{w}' in pattern")

      not Ast.capitalised?(w) ->
        {{:pvar, w}, advance(p)}

      true ->
        {name, p} = qualified_name(p)
        {args, p} = tight_list(p, :lparen, :rparen, &pattern/1)
        {{:pvariant, name, args || []}, p}
    end
  end

  defp if_expr(p, m) do
    p = advance(p)
    {cond_, p} = exp(p)
    {opener, p} = open_do(p)
    {then, p} = stmts(p, ["else", "end"])

    if at_kw?(p, "end") do
      error_here(
        p,
        "if requires an else branch — the `if` at #{elem(opener, 2)}:#{elem(opener, 3)} has none"
      )
    end

    {otherwise, p} = expect_keyword(p, "else")
    {tstmts, tlast} = into_block(then, otherwise)
    {estmts, elast, p} = rest_of_block(p)

    {{:if, m,
      [cond_, collapse(meta(opener), tstmts, tlast), collapse(meta(otherwise), estmts, elast)]},
     p}
  end

  defp fn_expr(p, m) do
    # `fn` closes with `end` but opens with no `do`, so it pushes its own opener.
    {t, p} = next(p)
    p = %{p | openers: [{"fn", elem(t, 2), elem(t, 3)} | p.openers]}
    {params, p} = params(p)
    {_, p} = expect(p, :arrow)
    {stmts, last, p} = rest_of_block(p)
    {{:fn, m, [params, collapse(m, stmts, last)]}, p}
  end

  # ---------- JSX (raw mode: `cur` is :raw, `lx` is the raw cursor) ----------

  defp raw_ok({:ok, v, lx}, p), do: {v, %{p | lx: lx}}
  defp raw_ok({:error, e}, _p), do: throw_lex(e)

  defp raw_consume(p, expected) do
    case Lexer.raw_consume(p.lx, expected) do
      {:ok, lx} -> %{p | lx: lx}
      {:error, e} -> throw_lex(e)
    end
  end

  # A tag or attribute name, and where it starts.
  defp jsx_name(p) do
    lx = Lexer.skip_raw_whitespace(p.lx)
    {line, col} = Lexer.position(lx)
    {name, p} = raw_ok(Lexer.jsx_name(lx), p)
    {name, line, col, p}
  end

  defp jsx_element(p), do: nested(p, &jsx_element_inner/1)

  defp jsx_element_inner(p) do
    {tag, line, col, p} = jsx_name(p)
    jsx_attrs(p, tag, line, col, [])
  end

  defp jsx_attrs(p, tag, line, col, attrs) do
    lx = Lexer.skip_raw_whitespace(p.lx)
    p = %{p | lx: lx}
    m = [line: line, col: col]

    case Lexer.raw_peek(lx) do
      ?> ->
        p = raw_consume(p, ">")
        {children, p} = jsx_children(p, tag, line, col, [])
        {{:jsx, m, [tag, Enum.reverse(attrs), children]}, p}

      ?/ ->
        p = raw_consume(p, "/>")
        {{:jsx, m, [tag, Enum.reverse(attrs), []]}, p}

      nil ->
        err_pos(line, col, "unterminated JSX element — `<#{tag}>` is never closed")

      _ ->
        {attr, p} = jsx_attr(p)
        jsx_attrs(p, tag, line, col, [attr | attrs])
    end
  end

  # `name="text"` or `name={e}`; `on-x={e}` is an event handler.
  defp jsx_attr(p) do
    {name, line, col, p} = jsx_name(p)
    p = raw_consume(p, "=")
    p = %{p | lx: Lexer.skip_raw_whitespace(p.lx)}

    case Lexer.raw_peek(p.lx) do
      ?" ->
        {{:str, text, _, _}, p} = raw_ok(Lexer.next_token(p.lx), p)

        if String.starts_with?(name, "on-") do
          err_pos(line, col, "event attribute '#{name}' requires an expression value in braces")
        else
          {{:text, name, text}, p}
        end

      ?{ ->
        {e, p} = interpolation(p)

        case name do
          "on-" <> event -> {{:event, event, e}, p}
          _ -> {{:expr, name, e}, p}
        end

      _ ->
        err_pos(line, col, "expected '\"' or '{' for attribute '#{name}'")
    end
  end

  # `{e}`: one expression in normal mode, through its `}`; the caller resumes
  # raw mode (the `}` is checked, not advanced past).
  defp interpolation(p) do
    p = p |> raw_consume("{") |> advance()
    {e, p} = exp(p)
    t = peek(p)

    if spec?(:rbrace, t) do
      {e, %{p | cur: :raw}}
    else
      err_at(t, "expected '}', got '#{describe(t)}'")
    end
  end

  # Text, interpolations and elements, through the closing tag of `tag`, which
  # opened at `line:col`.
  defp jsx_children(p, tag, line, col, acc) do
    {text, p} =
      case Lexer.jsx_text(p.lx) do
        {:ok, text, lx} ->
          {text, %{p | lx: lx}}

        {:error, _} ->
          err_pos(
            line,
            col,
            "unterminated JSX element — `<#{tag}>` opened here is never closed"
          )
      end

    text = String.trim(text)
    acc = if text == "", do: acc, else: [{:text, text} | acc]

    case {Lexer.raw_peek(p.lx), Lexer.raw_peek2(p.lx)} do
      {?{, _} ->
        {e, p} = interpolation(p)
        jsx_children(p, tag, line, col, [{:expr, e} | acc])

      {_, ?/} ->
        p = raw_consume(p, "</")
        {close, cl, cc, p} = jsx_name(p)
        p = raw_consume(p, ">")

        if close == tag do
          {Enum.reverse(acc), p}
        else
          err_pos(cl, cc, "mismatched closing tag </#{close}>, expected </#{tag}>")
        end

      _ ->
        p = raw_consume(p, "<")
        {el, p} = jsx_element(p)
        jsx_children(p, tag, line, col, [{:element, el} | acc])
    end
  end
end
