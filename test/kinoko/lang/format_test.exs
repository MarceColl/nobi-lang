defmodule Kinoko.Lang.FormatTest do
  use ExUnit.Case, async: true

  alias Kinoko.Lang.{Cid, Format, Parser}

  import YabuOracle, only: [strip: 1]

  defp parse!(src) do
    assert {:ok, decls} = Parser.program(src), src
    decls
  end

  defp survives(src) do
    program = parse!("def X.f() : Int do\n  #{src}\nend")
    assert strip(parse!(Format.program(program))) == strip(program), src
  end

  describe "the corpus" do
    test "writes what TS wrote" do
      for {label, src} <- YabuOracle.every_source(), not String.ends_with?(label, ".yabu") do
        {:ok, decls} = Parser.program(src)
        assert Format.program(decls) == String.trim_trailing(src), label
      end
    end

    test "formatting never changes the tree, and is idempotent" do
      for {label, src} <- YabuOracle.every_source() do
        {:ok, a} = Parser.program(src)
        {:ok, b} = a |> Format.program() |> Parser.program()
        assert strip(a) == strip(b), label
        assert Format.program(b) == Format.program(a), label
        assert Enum.map(a, &Cid.of/1) == Enum.map(b, &Cid.of/1), label
      end
    end

    test "corpus has a floor" do
      files = for {l, _} <- YabuOracle.every_source(), String.ends_with?(l, ".yabu"), do: l
      assert Enum.sort(files) == ~w(counter.yabu notes.yabu split.yabu todo.yabu)
    end
  end

  describe "declarations round trip" do
    test "each kind" do
      for src <- [
            "defapp Counter",
            "defmodel A.M do\n  x : Int\n  xs : List<String>\nend",
            "deftype Option<T> do\n  Some(T) | None\nend",
            "def A.f(m : A.M) : (Int, Bool) do\n  always(m.x >= 0)\n  y = 2 * 3\n  (y, \"quote \\\" here\" == \"line\\nbreak\")\nend",
            "def A.view(m : A.M) : Html do\n  <div class=\"app\">\n    <button on-click={A.Msg.Go}>Go now</button>\n    {m.x}\n  </div>\nend",
            "deftest A.t do\n  1 == 1\nend"
          ] do
        assert Format.program(parse!(src)) == src
      end
    end
  end

  describe "expression edge cases survive formatting" do
    test "precedence and associativity" do
      for src <- [
            "1 + 2 * 3",
            "(1 + 2) * 3",
            "1 - 2 - 3",
            "1 - (2 - 3)",
            "a ++ b + c",
            "(a ++ b) + c",
            "not (a or b)",
            "-(1 + 2)"
          ],
          do: survives(src)
    end

    test "constructs and control flow" do
      for src <- [
            "%M{m | a: 1, b: 2}",
            ~s|%{"k" => [1, 2], "j" => (1, true)}|,
            "if a do 1 else 2 end",
            "case x do\n    Some.A(n) -> n\n    _ -> 0\n  end",
            "fn (x : Int) -> x + 1 end",
            "f(g(h(1)))",
            "Store.get(k).value.inner"
          ],
          do: survives(src)
    end

    test "tuple patterns" do
      for src <- [
            "case p do\n    (a, _) -> a\n  end",
            "case p do\n    ((1, \"s\"), (b, true)) -> b\n    _ -> 0\n  end",
            "case o do\n    Option.Some((a, b)) -> a\n    _ -> 0\n  end",
            "case p do\n    (Option.Some(a), Option.None) -> a\n    _ -> 0\n  end",
            "case p do\n    (x) -> x\n  end"
          ],
          do: survives(src)

      {:ok, {:case, _, [_, arms]}} =
        Parser.expr(
          "case p do\n  ((1, \"s\"), Option.Some((b, true))) -> 1\n  ((x)) -> 2\n  ((y, z)) -> 3\nend"
        )

      assert Enum.map(arms, fn {p, _} -> Format.pattern(p) end) ==
               [~s|((1, "s"), Option.Some((b, true)))|, "x", "(y, z)"]
    end

    test "annotations" do
      for src <- [
            "(x : Int)",
            "([] : List<(Int -> Bool)>)",
            "((1, 2) : (Int, Int))",
            "((a : Int), (b : Int))",
            "(m : M.T).count",
            "-(x : Int) + (y : Int)",
            "((x : Int) : Int)",
            "(do\n    y = 1\n    y\n  end : Int)",
            "<p>{(x : String)}</p>"
          ],
          do: survives(src)

      {:ok, e} = Parser.expr("(\n  JSON.parse(s)   :Result<Int,String>)")
      assert Format.expr(e) == "(JSON.parse(s) : Result<Int, String>)"
    end

    test "a field of a capitalised name keeps its parentheses" do
      for src <- [
            "(M).x",
            "(Counter.init).count",
            "(M).x.y",
            "-(M).x",
            "not (M).x",
            "[(M).a]",
            "always((M).a)",
            "<p>{(M).a}</p>",
            "%M{(M).x | a: 1}",
            "fn (M : Int) -> (M).x end"
          ],
          do: survives(src)

      program = parse!("def A.f(M : A.M) : Int do\n  (M).x\nend")
      assert strip(parse!(Format.program(program))) == strip(program)
      assert Format.expr(elem(Parser.expr("(M).x"), 1)) == "(M).x"
    end

    test "types" do
      assert Format.type({:arrow, [], {:named, "Int"}}) == "(() -> Int)"
      assert Format.type({:arrow, [{:var, "a"}, {:var, "b"}], {:var, "b"}}) == "(a, b -> b)"
    end
  end

  describe "not exponential in depth" do
    @long "averyveryverylongidentifiername"

    defp nest(0, _), do: "x"
    defp nest(d, f), do: f.(nest(d - 1, f))

    defp within_budget(src) do
      decls = parse!(src)
      {us, out} = :timer.tc(fn -> Format.program(decls) end)
      assert us < 3_000_000, "formatting took #{us}us"
      assert strip(parse!(out)) == strip(decls)
    end

    test "nested jsx, case, if, fn, interpolation at depth 30" do
      jsx = nest(30, &"<div class=\"#{@long}\">#{&1}</div>")
      within_budget("def A.f() : Html do #{jsx} end")

      interp = nest(30, &"<div class=\"#{@long}\">{#{&1}}</div>")
      within_budget("def A.f() : Html do #{interp} end")

      cases = String.replace(nest(30, &"case #{@long}x do 1 -> #{&1} end"), "x end", "1 end")
      within_budget("def A.f(#{@long}x : Int) : Int do #{cases} end")

      ifs = String.replace(nest(30, &"if #{@long}x > 0 do #{&1} else 0 end"), "do x", "do 1")
      within_budget("def A.f(#{@long}x : Int) : Int do #{ifs} end")

      fns = nest(12, &"List.map([1], fn (#{@long}y : Int) -> #{&1} end)")
      within_budget("def A.f() : Int do #{fns} end")
    end
  end

  describe "Cid" do
    test "ignores layout and line endings, sees content" do
      {:ok, [a]} = Parser.program("def A.f() : Int do\n  1\nend")
      {:ok, [b]} = Parser.program("def A.f()   :   Int do\r\n\r\n      1\r\nend")
      {:ok, [c]} = Parser.program("def A.f() : Int do\n  2\nend")
      assert Cid.of(a) == Cid.of(b)
      refute Cid.of(a) == Cid.of(c)
      assert Cid.of(a) =~ ~r/^[0-9a-f]{64}$/
      assert Cid.version() == "yabu/1"
    end

    test "is sha256 of the version line and the canonical text" do
      {:ok, [a]} = Parser.program("defapp Counter")
      expect = :crypto.hash(:sha256, "yabu/1\ndefapp Counter") |> Base.encode16(case: :lower)
      assert Cid.of(a) == expect
    end

    test "of non-ASCII content is stable" do
      {:ok, [d]} = Parser.program(~s|def A.s() : String do\n  "猫\\t"\nend|)
      assert Cid.of(d) == Cid.of(d |> Format.decl() |> Parser.program() |> elem(1) |> hd())
    end
  end
end
