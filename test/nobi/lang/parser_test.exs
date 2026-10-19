defmodule Nobi.Lang.ParserTest do
  use ExUnit.Case, async: true

  alias Nobi.Lang.Parser

  import NobiOracle, only: [strip: 1]

  # Builders for stripped nodes.
  defp i(n), do: {:int, [n]}
  defp n(s), do: {:name, [s]}
  defp s(x), do: {:str, [x]}
  defp b(x), do: {:bool, [x]}
  defp bin(op, l, r), do: {:bin, [op, l, r]}
  defp t(name), do: {:named, name}
  defp field(e, f), do: {:field, [e, f]}
  defp pvar(x), do: {:pvar, x}

  defp expr!(src) do
    assert {:ok, e} = Parser.expr(src), src
    strip(e)
  end

  defp decl!(src) do
    assert {:ok, [d]} = Parser.program(src), src
    strip(d)
  end

  defp err(f, src) do
    assert {:error, %{code: "parse", message: m, line: l, col: c}} = apply(Parser, f, [src]), src
    {l, c, m}
  end

  defp fail(src) do
    case Parser.program(src) do
      {:ok, _} -> "(parsed)"
      {:error, %{message: m, line: l, col: c}} -> "#{l}:#{c}: #{m}"
    end
  end

  describe "decls" do
    test "def with params and return type" do
      assert decl!("def Math.add(a : Int, b : Int) : Int do a + b end") ==
               {:def,
                [
                  "Math.add",
                  [{"a", t("Int")}, {"b", t("Int")}],
                  t("Int"),
                  {:block, [[], bin(:+, n("a"), n("b"))]}
                ]}
    end

    test "def with no params" do
      assert {:def, ["Counter.zero", [], _, _]} = decl!("def Counter.zero() : Int do 0 end")
    end

    test "defmodel with fields" do
      assert decl!("defmodel Todo.Item do\n  id : Int\n  text : String\n  done : Bool\nend") ==
               {:defmodel,
                [
                  "Todo.Item",
                  [
                    {"id", t("Int"), :none},
                    {"text", t("String"), :none},
                    {"done", t("Bool"), :none}
                  ]
                ]}
    end

    test "deftype with variants" do
      assert decl!("deftype Counter.Msg do\n  Increment | Decrement | Add(Int)\nend") ==
               {:deftype,
                [
                  "Counter.Msg",
                  [],
                  [{"Increment", []}, {"Decrement", []}, {"Add", [t("Int")]}]
                ]}
    end

    test "deftype with generic params" do
      assert decl!("deftype Option<T> do\n  Some(T) | None\nend") ==
               {:deftype, ["Option", ["T"], [{"Some", [t("T")]}, {"None", []}]]}
    end

    test "deftype with variants across lines" do
      assert {:deftype, [_, _, variants]} =
               decl!("deftype T.Msg do\n  A\n  | B\n  | C(String)\nend")

      assert Enum.map(variants, &elem(&1, 0)) == ["A", "B", "C"]
    end

    test "defapp, deftest and multiple decls" do
      assert decl!("defapp Counter") == {:defapp, ["Counter"]}
      assert {:deftest, ["T.one", {:block, [[], {:int, [1]}]}]} = decl!("deftest T.one do 1 end")
      assert {:ok, ds} = Parser.program("defapp A\n\n\ndefapp B\n")
      assert Enum.map(ds, &Nobi.Lang.Ast.name/1) == ["A", "B"]
    end

    test "a lowercase-headed decl name is joined by dots" do
      assert {:def, ["a.b.c", [], _, _]} = decl!("def a.b.c() : Int do 1 end")
    end

    test "decl meta carries line and col" do
      assert {:ok, [{:defapp, [line: 2, col: 1], ["B"]}, _ | _]} =
               Parser.program("\ndefapp B\ndefapp C")
    end
  end

  describe "literals and collections" do
    test "scalars" do
      assert expr!("42") == i(42)
      assert expr!("-5") == {:neg, [i(5)]}
      assert expr!(~S|"a\"b\\c\nd\te"|) == s("a\"b\\c\nd\te")
      assert expr!("true") == b(true)
      assert expr!("false") == b(false)
      assert expr!("1.5") == {:float, [1.5]}
      assert expr!("-0.25") == {:neg, [{:float, [0.25]}]}
      assert expr!("2.0e-3 * x") == bin(:*, {:float, [0.002]}, n("x"))
    end

    test "a Float is not a pattern" do
      refused =
        "a Float is not a pattern — bind it and compare in an `if` (`x -> if x < 1.5 do … end`)"

      assert {_, _, ^refused} = err(:expr, "case x do\n  1.5 -> 1\n  _ -> 2\nend")
      assert {_, _, ^refused} = err(:expr, "case x do\n  -1.5 -> 1\n  _ -> 2\nend")
    end

    test "lists, maps, tuples, grouping" do
      assert expr!("[1, 2, 3]") == {:list, [i(1), i(2), i(3)]}
      assert expr!("[]") == {:list, []}
      assert expr!(~S|%{"a" => 1, "b" => 2}|) == {:map, [{s("a"), i(1)}, {s("b"), i(2)}]}
      assert expr!("%{}") == {:map, []}
      assert expr!("(1, 2)") == {:tuple, [i(1), i(2)]}
      assert expr!("(1)") == i(1)
    end

    test "an annotation wraps one expression" do
      assert expr!("(1 : Int)") == {:annot, [i(1), t("Int")]}

      assert expr!("(\n  [] : List<M.T>\n)") ==
               {:annot, [{:list, []}, {:applied, "List", [t("M.T")]}]}

      assert expr!("((1, 2) : (Int, Int))") ==
               {:annot, [{:tuple, [i(1), i(2)]}, {:tuple, [t("Int"), t("Int")]}]}

      assert expr!("((a : Int), (b : Int))") ==
               {:tuple, [{:annot, [n("a"), t("Int")]}, {:annot, [n("b"), t("Int")]}]}

      assert expr!("(m : M.T).count") == field({:annot, [n("m"), t("M.T")]}, "count")
    end

    test "an annotation inside a tuple's parentheses is refused" do
      refused =
        "an annotation wraps one expression in parentheses of its own — " <>
          "`((a, b) : (A, B))` annotates a tuple, `((a : A), (b : B))` its items"

      for {src, col} <- [
            {"(a, b : Int)", 7},
            {"(a : Int, b)", 9},
            {"(1, 2, 3 : (Int, Int, Int))", 10}
          ] do
        assert err(:expr, src) == {1, col, refused}, src
      end
    end
  end

  describe "operators" do
    test "precedence and associativity" do
      assert expr!("1 + 2 * 3") == bin(:+, i(1), bin(:*, i(2), i(3)))

      assert expr!("a or b and 1 < 2") ==
               bin(:or, n("a"), bin(:and, n("b"), bin(:<, i(1), i(2))))

      assert expr!("a ++ b + c") == bin(:++, n("a"), bin(:+, n("b"), n("c")))
      assert expr!("a == b < c") == bin(:==, n("a"), bin(:<, n("b"), n("c")))
      assert expr!("1 - 2 - 3") == bin(:-, bin(:-, i(1), i(2)), i(3))
    end

    test "not and neg are unary" do
      assert expr!("not a and -b < 3") ==
               bin(:and, {:not, [n("a")]}, bin(:<, {:neg, [n("b")]}, i(3)))
    end

    test "a < b is a comparison, not JSX" do
      assert expr!("a < b") == bin(:<, n("a"), n("b"))
    end

    test "a newline after a binary operator continues the expression" do
      assert expr!("1 +\n  2") == bin(:+, i(1), i(2))
    end
  end

  describe "names, calls, fields" do
    test "lowercase head gives a field chain; capitalised head a dotted name" do
      assert expr!("model.a.b") == field(field(n("model"), "a"), "b")
      assert expr!("Counter.Msg.Increment") == n("Counter.Msg.Increment")
    end

    test "calls" do
      assert expr!("List.map(xs, f)") == {:call, ["List.map", [n("xs"), n("f")]]}
      assert expr!("f(1)") == {:call, ["f", [i(1)]]}
      assert expr!("Store.get(k).value") == field({:call, ["Store.get", [n("k")]]}, "value")
    end

    test "a. and A. followed by a non-identifier" do
      for src <- ["a.", "A.", "a.1", "A.1"] do
        assert err(:expr, src) == {1, 2, "unexpected '.' after expression"}, src
      end
    end
  end

  describe "construct and update" do
    test "construct" do
      assert expr!("%Counter.Model{count: 0}") ==
               {:construct, ["Counter.Model", [{"count", i(0)}]]}

      assert expr!("%Empty{}") == {:construct, ["Empty", []]}
    end

    test "update" do
      assert expr!("%Counter.Model{model | count: model.count + 1}") ==
               {:update,
                [
                  "Counter.Model",
                  n("model"),
                  [{"count", bin(:+, field(n("model"), "count"), i(1))}]
                ]}
    end
  end

  describe "case" do
    test "all pattern kinds" do
      src =
        "case x do\n  Counter.Msg.Add(n) -> n\n  1 -> 2\n  \"s\" -> 3\n  true -> 4\n  y -> y\n  _ -> 0\nend"

      assert expr!(src) ==
               {:case,
                [
                  n("x"),
                  [
                    {{:pvariant, "Counter.Msg.Add", [pvar("n")]}, n("n")},
                    {{:pint, 1}, i(2)},
                    {{:pstr, "s"}, i(3)},
                    {{:pbool, true}, i(4)},
                    {pvar("y"), n("y")},
                    {:wild, i(0)}
                  ]
                ]}
    end

    test "nested variant patterns" do
      assert {:case, [_, [{p, _}, _]]} =
               expr!("case x do\n  Option.Some(Option.Some(v)) -> v\n  _ -> 0\nend")

      assert p == {:pvariant, "Option.Some", [{:pvariant, "Option.Some", [pvar("v")]}]}
    end

    test "tuple patterns" do
      src =
        "case x do\n  (a, _) -> 1\n  ((1, \"s\"), Option.Some((b, true))) -> 2\n  " <>
          "(Option.None, -3) -> 3\n  (c) -> 4\nend"

      assert {:case, [_, arms]} = expr!(src)

      assert Enum.map(arms, &elem(&1, 0)) == [
               {:ptuple, [pvar("a"), :wild]},
               {:ptuple,
                [
                  {:ptuple, [{:pint, 1}, {:pstr, "s"}]},
                  {:pvariant, "Option.Some", [{:ptuple, [pvar("b"), {:pbool, true}]}]}
                ]},
               {:ptuple, [{:pvariant, "Option.None", []}, {:pint, -3}]},
               pvar("c")
             ]
    end

    test "a binding never destructures a tuple" do
      refused = "a binding names one value — take a tuple apart with `case p do (a, b) -> … end`"

      for {src, line} <- [
            {"def A.f(p : (Int, Int)) : Int do\n  (a, b) = p\n  a\nend", 2},
            {"def A.f(p : (Int, Int)) : Int do\n  x = 1\n  (a, b) = p\n  a\nend", 3}
          ] do
        assert err(:program, src) == {line, 10, refused}
      end

      assert err(:program, "def A.f(p : (Int, Int)) : Int do\n  [a] = p\n  a\nend") ==
               {2, 7, "expected a newline or 'end', got '='"}
    end

    test "a call that swallows the next arm's pattern says so" do
      swallowed = fn call ->
        "the call `#{call}` swallowed the next arm's tuple pattern — start each arm on its own line"
      end

      assert err(:expr, "case (1, false) do (n, true) -> n (n, false) -> 0 - n end") ==
               {1, 46, swallowed.("n(n, false)")}

      assert err(:expr, "case (1, false) do (n, false) -> 0 - n (n, true) -> n end") ==
               {1, 50, swallowed.("n(n, true)")}

      assert {:ok, _} =
               Parser.expr("case (1, false) do\n  (n, true) -> n\n  (n, false) -> 0 - n\nend")

      assert err(:expr, "case x do 1 -> 2 -> 3 end") == {1, 18, "expected a pattern, got '->'"}

      assert err(:expr, "case x do\n  1 -> f(2)\n  -> 3\nend") ==
               {3, 3, "expected a pattern, got '->'"}
    end

    test "arm body on the next line" do
      assert {:case, [_, [{_, body1}, {_, body2}]]} =
               expr!("case x do\n  1 ->\n    2\n  _ -> 3\nend")

      assert {body1, body2} == {i(2), i(3)}
    end
  end

  describe "if, fn, blocks" do
    test "inline if" do
      assert expr!("if a do 1 else 2 end") == {:if, [n("a"), i(1), i(2)]}
    end

    test "multiline if with bindings becomes block branches" do
      assert expr!("if a do\n  x = 1\n  x\nelse\n  2\nend") ==
               {:if, [n("a"), {:block, [[{:bind, "x", i(1)}], n("x")]}, i(2)]}
    end

    test "if requires else" do
      assert {1, _, m} = err(:expr, "if a do 1 end")
      assert m =~ "if requires an else branch"
    end

    test "if branch blocks carry the meta of their opener" do
      src = "if a do\n  x = 1\n  x\nelse\n  y = 2\n  y\nend"

      assert {:ok, {:if, _, [_, {:block, [line: 1, col: _], _}, {:block, [line: 4, col: _], _}]}} =
               Parser.expr(src)
    end

    test "fn with typed params" do
      assert expr!("fn (x : Int, y : Int) -> x + y end") ==
               {:fn, [[{"x", t("Int")}, {"y", t("Int")}], bin(:+, n("x"), n("y"))]}
    end

    test "do block with bindings; single expression collapses" do
      assert expr!("do\n  a = 1\n  a + 1\nend") ==
               {:block, [[{:bind, "a", i(1)}], bin(:+, n("a"), i(1))]}

      assert expr!("do 5 end") == i(5)
    end

    test "always and sometimes" do
      assert expr!("always(x >= 0)") == {:always, [bin(:>=, n("x"), i(0))]}
      assert expr!("sometimes(true)") == {:sometimes, [b(true)]}
    end

    test "a block needs an expression and cannot end with a binding" do
      assert err(:expr, "do end") == {1, 4, "a block needs an expression before `end`"}

      assert err(:program, "def A.f() : Int do\n  x = 1\nend") ==
               {3, 1, "a block cannot end with a binding: `x = …`"}
    end
  end

  describe "types" do
    defp ret_of(src) do
      assert {:def, [_, _, ret, _]} = decl!("def F.f() : #{src} do 0 end")
      ret
    end

    test "applied, nested, dotted" do
      assert ret_of("List<Int>") == {:applied, "List", [t("Int")]}
      assert ret_of("Map<String, Int>") == {:applied, "Map", [t("String"), t("Int")]}

      assert ret_of("Map<String, List<Int>>") ==
               {:applied, "Map", [t("String"), {:applied, "List", [t("Int")]}]}

      assert ret_of("Cmd<Counter.Msg>") == {:applied, "Cmd", [t("Counter.Msg")]}
    end

    test "arrow and tuple" do
      assert ret_of("(Int, Int -> Bool)") == {:arrow, [t("Int"), t("Int")], t("Bool")}

      assert ret_of("(Counter.Model, Cmd<Counter.Msg>)") ==
               {:tuple, [t("Counter.Model"), {:applied, "Cmd", [t("Counter.Msg")]}]}

      assert ret_of("List<(Int -> Bool)>") ==
               {:applied, "List", [{:arrow, [t("Int")], t("Bool")}]}
    end
  end

  describe "jsx" do
    defp el(tag, attrs, children), do: {:jsx, [tag, attrs, children]}

    test "element with text and event attr" do
      assert expr!("<button on-click={M.Inc}>+</button>") ==
               el("button", [{:event, "click", n("M.Inc")}], [{:text, "+"}])
    end

    test "text, expr and event attrs together" do
      assert expr!(~S|<input class="big" value={model.input} on-change={M.Set} />|) ==
               el(
                 "input",
                 [
                   {:text, "class", "big"},
                   {:expr, "value", field(n("model"), "input")},
                   {:event, "change", n("M.Set")}
                 ],
                 []
               )
    end

    test "nested elements and expr children" do
      assert expr!("<div>\n  <span>{model.count}</span>\n  <ul>{items}</ul>\n</div>") ==
               el("div", [], [
                 {:element, el("span", [], [{:expr, field(n("model"), "count")}])},
                 {:element, el("ul", [], [{:expr, n("items")}])}
               ])
    end

    # React's rule: whitespace runs that hold a newline are layout and go;
    # spaces within a line are content and stay.
    test "JSX text keeps in-line spaces and drops layout whitespace" do
      texts = fn src ->
        {:jsx, [_, _, children]} = expr!(src)
        for {:text, t} <- children, do: t
      end

      assert texts.("<span>by {name}</span>") == ["by "]
      assert texts.("<span>{a} {b}</span>") == [" "]
      assert texts.("<span>{a} x{b}</span>") == [" x"]
      assert texts.("<p> hi </p>") == [" hi "]
      assert texts.("<p>  two  spaces  </p>") == ["  two  spaces  "]
      assert texts.("<p>\n  {a}\n  {b}\n</p>") == []
      assert texts.("<p>\n  one\n    two  \n  three\n</p>") == ["one two three"]
      assert texts.("<p>by \n  {a}</p>") == ["by"]
      assert texts.("<p>{a}\n  , then</p>") == [", then"]
    end

    test "text child with internal spaces" do
      assert {:jsx, [_, [], [{:text, "Clear done"}]]} = expr!("<button>Clear done</button>")
    end

    test "an expr attr containing if" do
      assert {:jsx, [_, [{:expr, "class", cond_}], []]} =
               expr!(~S|<li class={if d do "a" else "b" end} />|)

      assert cond_ == {:if, [n("d"), s("a"), s("b")]}
    end

    test "a mismatched close tag is positioned at the closing name" do
      assert {1, 9, m} = err(:expr, "<div>x</span>")
      assert m =~ "span"
    end

    test "an element starts wherever an operand is expected" do
      assert expr!("a < <b/>") == bin(:<, n("a"), el("b", [], []))
      assert expr!("<a/> == <b/>") == bin(:==, el("a", [], []), el("b", [], []))

      assert decl!("def A.f() : Html do\n  x = <div/>\n  x\nend") ==
               {:def,
                ["A.f", [], t("Html"), {:block, [[{:bind, "x", el("div", [], [])}], n("x")]}]}
    end

    test "whitespace inside tags is skipped" do
      assert expr!("< div >x</ div >") == el("div", [], [{:text, "x"}])

      assert {:jsx, [_, [{:text, "x", "1"}, {:expr, "y", {:int, [2]}}], []]} =
               expr!("<a x = \"1\"\n   y = {2}/>")
    end

    test "errors are positioned where TS reports them" do
      cases = [
        {~S|<div class="a"|, 1, 2, "unterminated JSX element — `<div>` is never closed"},
        {"<a>\n <b>\n  text", 2, 3,
         "unterminated JSX element — `<b>` opened here is never closed"},
        {~S|<b on-click="x"/>|, 1, 4,
         "event attribute 'on-click' requires an expression value in braces"},
        {"<b x=1/>", 1, 4, "expected '\"' or '{' for attribute 'x'"},
        {"<b x/>", 1, 5, "expected '='"},
        {"<1/>", 1, 2, "expected a JSX name"},
        {"<a></", 1, 6, "expected a JSX name"},
        {"<a / >", 1, 4, "expected '/>'"},
        {"<a>{#}</a>", 1, 5, "unexpected character '#'"}
      ]

      for {src, line, col, message} <- cases do
        assert err(:expr, src) == {line, col, message}, src
      end
    end
  end

  describe "errors carry position" do
    test "unclosed do" do
      assert {1, 21, _} = err(:program, "def A.f() : Int do 1")
    end

    test "bad token" do
      assert {1, 3, _} = err(:expr, "1 @ 2")
    end

    test "keyword in wrong position" do
      assert {1, 5, _} = err(:program, "def do() : Int do 1 end")
    end

    test "lexing errors surface through the parser" do
      assert {1, 5, m} = err(:expr, "1 + 99999999999999999999")
      assert m =~ "too large"
      assert {1, 1, "unterminated string"} = err(:expr, ~S|"abc|)
      assert {1, 1, "newline in string literal"} = err(:expr, "\"a\nb\"")
    end

    test "invalid UTF-8 is a parse error" do
      assert {:error, %{code: "parse", line: 1, col: 1}} = Parser.program(<<"def ", 0xFF>>)
      assert {:error, %{code: "parse"}} = Parser.expr(<<0xFF>>)
    end

    test "trailing garbage after an expression" do
      assert {1, 3, "unexpected ')' after expression"} = err(:expr, "1 )")
    end

    test "an int past i64 is a parse error" do
      assert {:error, %{code: "parse"}} = Parser.expr("9223372036854775808")
      assert {:ok, _} = Parser.expr("9223372036854775807")
    end
  end

  describe "the parser names the shape that works" do
    test "a record literal missing its percent" do
      assert {_, _, m} = err(:expr, "Game.Board{moves: 1}")
      assert m =~ "write `%Game.Board{field: value}`"
    end

    test "a bare brace names both things braces belong to" do
      assert {_, _, m} = err(:expr, "{moves: 1}")
      assert m =~ "%Model{field: value}" and m =~ "%{key => value}"
    end

    test "named arguments are refused by name" do
      for src <- ["Game.Board(moves: 1)", "Game.Board(moves = 1)"] do
        assert {_, _, m} = err(:expr, src)
        assert m =~ "Nobi has no named arguments", src
      end
    end

    test "everything these messages recommend is valid" do
      assert {:ok, _} = Parser.expr("%Game.Board{moves: 1}")
      assert {:ok, _} = Parser.expr("%Game.Board{row | moves: 1}")
      assert {:ok, _} = Parser.expr(~S|%{"k" => 1}|)
    end
  end

  describe "depth" do
    test "max_depth" do
      assert Parser.max_depth() == 512
    end

    test "nesting past max_depth is a parse error, not a crash" do
      deep = String.duplicate("(", 10_000) <> "1" <> String.duplicate(")", 10_000)
      assert {:error, %{code: "parse"}} = Parser.expr(deep)
    end

    test "other deep shapes are diagnostics, not crashes" do
      shapes = [
        {"[", "1", "]"},
        {"-", "1", ""},
        {"not ", "true", ""},
        {"A.g(", "1", ")"},
        {"<div>", "x", "</div>"},
        {"if true do ", "1", " else 1 end"},
        {"case 1 do 1 -> ", "1", " end"}
      ]

      for {open, leaf, close} <- shapes do
        src = String.duplicate(open, 5000) <> leaf <> String.duplicate(close, 5000)
        assert {:error, %{code: "parse"}} = Parser.expr(src), open
      end
    end

    test "a long operator chain is refused, a short one parses" do
      assert {:error, %{code: "parse"}} = Parser.expr(String.duplicate("1 + ", 50_000) <> "1")
      assert {:error, %{code: "parse"}} = Parser.expr("x" <> String.duplicate(".a", 50_000))
      assert {:ok, _} = Parser.expr("x" <> String.duplicate(".a", 400))
    end

    test "legal nesting is untouched" do
      assert {:ok, _} =
               Parser.expr(String.duplicate("(", 200) <> "1" <> String.duplicate(")", 200))
    end
  end

  describe "an unterminated construct names where it opened" do
    defp blames(src, at), do: assert(fail(src) =~ "unclosed `do` opened at #{at}")

    test "def, defmodel and case bodies blame the opener" do
      blames("def A.f() : Int do\n  1\n\ndeftype B.C do\n  X\nend\n", "1:17")
      blames("defmodel A.M do\n  x : Int\n\ndef B.f() : Int do 1 end\n", "1:14")
      blames("def A.f(x : Int) : Int do\n  case x do\n    1 -> 1\nend\n\ndefapp Z\n", "1:24")
      blames("def A.f(x : Int) : Int do\n  case x do\n    1 -> 2\n", "2:10")
      blames("def A.f(x : Int) : Int do\n  case x do\n    1 -> 2\n\ndefapp Z\n", "2:10")
      blames("def A.f() : Int do\n  1\n", "1:17")

      blames(
        "def A.f() : Int do\n  List.map([1], fn (y : Int) -> y end)\n  1\n\ndefapp Z\n",
        "1:17"
      )

      blames("def A.f(x : Int) : Int do\n  case x do 1 -> 1 end\n  1\n\ndefapp Z\n", "1:24")
      blames("deftype A.T do\n  X | Y\n", "1:13")
    end

    test "an if with no else says where the if is" do
      m = fail("def A.f(x : Int) : Int do\n  if x > 0 do\n    1\n  end\nend\n")
      assert m =~ "if requires an else branch"
      assert m =~ "2:12"
    end

    test "an unclosed element names the tag and its position" do
      m = fail("def A.f() : Html do\n  <div class=\"a\">\n    <span>x</span>\n end\n")
      assert m =~ "`<div>`"
      assert m =~ "2:4"
    end

    test "closed constructs keep the opener stack balanced" do
      for src <- [
            "def A.f() : Int do\n  List.map([1], fn (y : Int) -> y end)\n  1\nend\n",
            "defmodel A.M do\n  x : Int\nend\n",
            "deftype A.T do\n  X | Y\nend\n",
            "def A.f(x : Int) : Int do\n  case x do\n    1 -> 1\n  end\nend\n",
            "def A.f(x : Int) : Int do\n  if x > 0 do 1 else 0 end\nend\n",
            "def A.f() : Int do\n  do\n    1\n  end\nend\n"
          ] do
        assert fail(src) == "(parsed)", src
      end
    end
  end

  describe "golden programs" do
    test "every golden program parses" do
      for {label, src} <- NobiOracle.every_source() do
        assert {:ok, [_ | _]} = Parser.program(src), label
      end
    end

    test "the counter app parses to the expected declarations" do
      {:ok, decls} = Parser.program(NobiOracle.corpus_source("counter.nobi"))
      assert Enum.map(decls, &elem(&1, 0)) == [:defmodel, :deftype, :def, :def, :def, :defapp]

      assert {:def, _,
              [
                "Counter.view",
                [{"model", {:named, "Counter.Model"}}],
                {:applied, "Html", [{:named, "Counter.Msg"}]},
                _
              ]} = Enum.at(decls, 4)
    end
  end
end
