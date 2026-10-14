defmodule Kinoko.Lang.CheckTest do
  @moduledoc """
  The checker against the Rust crate's `tests/types_check.rs` (itself TS's
  `typecheck`/`review-fixes` tests). The corpus, `defapp`, JSX and event,
  unbound-name hint and map-key cases close the file.
  """
  use ExUnit.Case, async: true

  import Kinoko.Lang.CheckHelpers

  alias Kinoko.Lang.Parser
  alias Kinoko.Lang.Types.{Check, Extract, Stdlib}
  alias Kinoko.Lang.Types.Check.{Ctx, Decl}

  @int {:named, "Int"}
  @string {:named, "String"}

  # ---------- typecheck.test.ts "inference" ----------

  test "generic instantiation through List.map" do
    typed =
      checks(
        "def A.f(xs : List<Int>) : List<String> do List.map(xs, fn (x : Int) -> String.from_int(x) end) end"
      )

    assert ty(typed) == {:applied, "List", [@string]}
  end

  test "== is polymorphic but requires matching sides" do
    assert ty(checks(~S|def A.f() : Bool do "x" == "y" end|)) == named("Bool")
    assert first_error(~S|def A.f() : Bool do "x" == 1 end|).code == "mismatch"
  end

  test "occurs check fires instead of looping" do
    err = first_error("def A.f(xs : List<Int>) : Int do List.length(List.append(xs, xs)) end")
    assert err.code in ["occurs", "mismatch"]
  end

  test "an unforced empty list cannot infer" do
    assert first_error("def A.f() : Int do x = [] \n 1 end").code == "cannot-infer"
  end

  # ---------- "errors are readable and precise" ----------

  test "unbound symbol names the symbol" do
    err = first_error("def A.f() : Int do B.missing(1) end")
    assert err.code == "unbound"
    assert err.message =~ "B.missing"
  end

  test "arity mismatch says expected vs got" do
    err = first_error("def A.g(x : Int) : Int do x end\ndef A.f() : Int do A.g(1, 2) end")
    assert err.code == "arity"
    assert err.message =~ ~r/expects 1.*got 2/
  end

  test "operand mismatch quotes the offending expression" do
    err = first_error(~S|def A.f() : Int do 1 + "x" end|)
    assert err.code == "mismatch"
    assert err.message =~ ~S|"x"|
  end

  test "a binder inside a variant pattern does not make the case exhaustive" do
    err =
      first_error("""
      deftype B.T do X(Int) | Y end
      def B.f(t : B.T) : Int do case t do B.T.X(n) -> n end end
      """)

    assert err.code == "non-exhaustive"
    assert err.message =~ "Y"
  end

  test "a non-exhaustive case lists the missing variants" do
    err =
      first_error("""
      deftype A.T do L | R | M end
      def A.f(t : A.T) : Int do case t do A.T.L -> 1 end end
      """)

    assert err.code == "non-exhaustive"
    assert err.message =~ "R"
    assert err.message =~ "M"
  end

  test "construct with missing and extra fields" do
    model = "defmodel A.M do x : Int\n y : String end\n"
    assert first_error(model <> "def A.f() : A.M do %A.M{x: 1} end").code == "missing-field"

    assert first_error(model <> ~S|def A.f() : A.M do %A.M{x: 1, y: "a", z: true} end|).code ==
             "extra-field"
  end

  test "a def whose final segment is capitalized violates the naming convention" do
    assert first_error("def A.Bad() : Int do 1 end").code == "bad-name"
  end

  # ---------- "models are persistent data" ----------

  test "arrow-typed and Cmd fields are rejected" do
    assert first_error("defmodel A.M do f : (Int -> Int) end").code == "invalid-model-field"
    assert first_error("defmodel A.M do c : Cmd<Int> end").code == "invalid-model-field"
  end

  # ---------- "typed output feeds codegen" ----------

  test "resolutions are attached" do
    typed =
      all_ok("""
      deftype R.Msg do Add(Int) end
      def R.f() : R.Msg do R.Msg.Add(1) end
      def R.g(n : Int) : R.Msg do R.Msg.Add(n) end
      """)

    add = {:variant, "R.Msg", "Add", 1}
    {:def, _, [_, _, _, {:block, _, [[], last]}]} = typed["R.f"]
    assert {:call, _, _} = last
    assert {ty(last), res(last)} == {named("R.Msg"), add}

    {:def, _, [_, _, _, {:block, _, [[], {:call, _, [_, [arg]]} = last]}]} = typed["R.g"]
    assert res(last) == add
    assert {ty(arg), res(arg)} == {@int, :local}
  end

  test "signature-only checking: a dependent sees the signature, not the body" do
    [g] = parse("def A.g() : Int do 1 end")
    [f] = parse("def A.f() : Int do A.g() + 1 end")
    sigs = Map.put(Stdlib.signatures(), "A.g", Extract.signature(g))
    checked = Check.decl(f, sigs)
    assert {:ok, _} = checked.result
    assert checked.deps == MapSet.new(["A.g"])
  end

  test "sigs may be a lookup function, consulted exactly as a map is" do
    [g] = parse("def A.g() : Int do 1 end")
    [f] = parse("def A.f() : Int do A.g() + List.length([1]) end")
    sigs = Map.put(Stdlib.signatures(), "A.g", Extract.signature(g))
    by_map = Check.decl(f, sigs)
    by_fun = Check.decl(f, &Map.get(sigs, &1))
    assert by_map == by_fun
    assert by_fun.deps == MapSet.new(["A.g", "List.length"])

    program = Check.program([f, g], &Map.get(Stdlib.signatures(), &1))
    assert program == Check.program([f, g], Stdlib.signatures())
  end

  # ---------- names that do not resolve ----------

  @game """
  defmodel Game.Board do
    id : Uuid
    moves : Int
    winner : String
  end
  deftype Game.Turn do
    X | O
  end
  def Game.other(t : Game.Turn) : Game.Turn do
    case t do
      Game.Turn.X -> Game.Turn.O
      Game.Turn.O -> Game.Turn.X
    end
  end
  """

  defp probe(body), do: first_error(@game <> "def Game.probe() : Int do #{body} end").message

  test "a name with nothing behind it is plainly unbound" do
    assert probe("Nowhere.at_all(1)") == "unbound symbol `Nowhere.at_all`"
    assert probe("Repo.insert(1)") == "unbound symbol `Repo.insert`"
  end

  test "a diagnostic lookup is not a dependency" do
    deps = fn body -> last_checked(@game <> "def Game.probe() : Int do #{body} end").deps end
    assert deps.("Game.Board.new(1)") == MapSet.new(["Game.Board.new"])
    assert deps.("board(1, 2)") == MapSet.new()
    assert deps.("List.fold(1)") == MapSet.new(["List.fold"])
  end

  # ---------- review-fixes.test.ts ----------

  @wrap """
  deftype In.T do A | B end
  deftype Out.T do Wrap(In.T) end
  """

  test "Wrap(In.T.A) does not cover all Wrap" do
    src = @wrap <> "def F.f(o : Out.T) : Int do case o do Out.T.Wrap(In.T.A) -> 1 end end"
    assert first_error(src).code == "non-exhaustive"
  end

  test "Wrap(x) with a binder still covers all Wrap" do
    checks(@wrap <> "def F.f(o : Out.T) : Int do case o do Out.T.Wrap(inner) -> 1 end end")
  end

  test "an arrow inside a deftype variant is rejected" do
    assert first_error("deftype Box.T do Fn((Int -> Int)) end").code == "invalid-model-field"
  end

  test "user code cannot define into compiler-owned namespaces" do
    assert first_error("def List.map(x : Int) : Int do x end").code == "bad-name"
    assert first_error("def Cmd.none() : Int do 1 end").code == "bad-name"
  end

  test "same-scope rebinding is rejected" do
    assert first_error("def F.f() : Int do x = 1 \n x = 2 \n x end").code == "bad-name"
  end

  test "binding a function to a name is rejected" do
    assert first_error("def F.f() : Int do g = fn (x : Int) -> x end \n g(1) end").code ==
             "bad-name"
  end

  # ---------- Rust-only ----------

  test "a model reached only through a call's return type is a dependency" do
    checked =
      last_checked("""
      defmodel A.M do count : Int end
      def A.g() : A.M do %A.M{count: 1} end
      def A.f() : Int do A.g().count end
      """)

    assert {:ok, _} = checked.result
    assert checked.deps == MapSet.new(["A.g", "A.M"])
  end

  test "a quoted expression is cut at 200 characters" do
    long = String.duplicate("x", 300)
    cut = ~S|"| <> String.duplicate("x", 199) <> "…"

    operand = first_error(~s|def A.f() : Int do 1 + "#{long}" end|)
    assert operand.code == "mismatch"
    assert operand.message =~ cut
    refute operand.message =~ long

    arity =
      first_error(~s|def A.g(x : Int) : Int do x end\ndef A.f() : Int do A.g(1, "#{long}") end|)

    assert arity.code == "arity"
    assert arity.message =~ ~S|A.g(1, "xxx|
    refute arity.message =~ long
    assert arity.message =~ "…"
  end

  test "a hostile block binder is refused" do
    err = first_error("def A.f() : Int do prototype = 1 \n prototype end")
    assert err.code == "bad-name"
    assert err.message =~ "prototype"
  end

  # Rust's parser refuses 510 nested ifs; this port's raw-nesting bound
  # (Task 3 ruling) refuses 512. The deepest body that parses checks.
  test "511 nested ifs, the parser's limit, check" do
    nested = fn depth ->
      "def A.f() : Int do " <>
        String.duplicate("if true do ", depth) <>
        "1" <> String.duplicate(" else 2 end", depth) <> " end"
    end

    assert {:error, %{code: "parse", message: "nesting too deep (limit 512)"}} =
             Parser.program(nested.(512))

    assert ty(checks(nested.(511))) == @int
  end

  test "an unknown fn parameter type is unbound" do
    err =
      first_error("def A.f() : Int do List.length(List.map([1], fn (x : A.Nope) -> 1 end)) end")

    assert err.code == "unbound"
    assert err.message =~ "A.Nope"
  end

  # ---------- Rust-only: patterns and exhaustiveness ----------

  @levels """
  deftype L.C do P | Q end
  deftype L.B do Mid(L.C, Int) | Flat end
  deftype L.A do Top(L.B) | Bare(Int) | Done end
  """

  defp levels(arms), do: @levels <> "def L.f(a : L.A) : Int do case a do\n#{arms}\nend end"
  defp arm_lines(lines), do: Enum.join(lines, "\n")

  test "three levels of nested variants are exhaustive when an irrefutable arm covers each variant" do
    for arms <- [
          arm_lines([
            "L.A.Top(L.B.Mid(L.C.P, n)) -> n",
            "L.A.Top(L.B.Mid(c, 0)) -> 0",
            "L.A.Top(_) -> 1",
            "L.A.Bare(n) -> n",
            "L.A.Done -> 2"
          ]),
          arm_lines([
            "L.A.Top(L.B.Mid(L.C.P, 0)) -> 0",
            "L.A.Top(b) -> 1",
            "L.A.Bare(_) -> 0",
            "L.A.Done -> 2"
          ]),
          arm_lines(["L.A.Top(L.B.Mid(L.C.Q, 3)) -> 3", "L.A.Top(L.B.Flat) -> 1", "other -> 0"])
        ] do
      assert ty(checks(levels(arms))) == @int, arms
    end
  end

  test "three levels of nested variants are not exhaustive when only refutable arms match a variant" do
    for {arms, missing} <- [
          {arm_lines([
             "L.A.Top(L.B.Mid(L.C.P, n)) -> n",
             "L.A.Top(L.B.Mid(c, 0)) -> 0",
             "L.A.Top(L.B.Flat) -> 1",
             "L.A.Bare(n) -> n",
             "L.A.Done -> 2"
           ]), "L.A.Top"},
          {arm_lines([
             "L.A.Top(L.B.Mid(L.C.P, n)) -> n",
             "L.A.Top(L.B.Mid(L.C.Q, n)) -> n",
             "L.A.Top(L.B.Flat) -> 1",
             "L.A.Bare(n) -> n",
             "L.A.Done -> 2"
           ]), "L.A.Top"},
          {arm_lines(["L.A.Top(L.B.Mid(c, n)) -> n", "L.A.Bare(_) -> 0", "L.A.Done -> 2"]),
           "L.A.Top"},
          {arm_lines(["L.A.Top(L.B.Mid(c, n)) -> n"]), "L.A.Top, L.A.Bare, L.A.Done"},
          {arm_lines(["L.A.Top(_) -> 0", "L.A.Bare(0) -> 0", "L.A.Done -> 2"]), "L.A.Bare"}
        ] do
      err = first_error(levels(arms))
      assert err.code == "non-exhaustive", arms
      assert err.message == "case on `L.A` is not exhaustive — missing: #{missing}", arms
    end
  end

  test "a nested pattern's coverage never reaches the enclosing case" do
    two = """
    deftype In.T do A | B end
    deftype Out.T do A(In.T) | B end
    def F.f(o : Out.T) : Int do case o do Out.T.A(In.T.A) -> 1
     Out.T.B -> 2 end end
    """

    three = """
    deftype L.C do Top | Q end
    deftype L.B do Mid(L.C) | Done end
    deftype L.A do Top(L.B) | Done end
    def L.f(a : L.A) : Int do case a do
      L.A.Top(L.B.Mid(L.C.Top)) -> 0
      L.A.Top(L.B.Done) -> 1
      L.A.Done -> 2
    end end
    """

    for {src, message} <- [
          {two, "case on `Out.T` is not exhaustive — missing: Out.T.A"},
          {three, "case on `L.A` is not exhaustive — missing: L.A.Top"}
        ] do
      err = first_error(src)
      assert {err.code, err.message} == {"non-exhaustive", message}
    end
  end

  @box "deftype G.Box<T> do Full(T) | Empty end\n"

  test "a generic deftype's variant binds its argument at the scrutinee's type" do
    typed =
      checks(
        @box <>
          ~S|def G.f(b : G.Box<String>) : String do case b do G.Box.Full(s) -> s| <>
          "\n" <> ~S| G.Box.Empty -> "" end end|
      )

    assert ty(typed) == @string
    {:case, _, [scrutinee, [{_, arm0} | _]]} = typed
    assert ty(scrutinee) == {:applied, "G.Box", [@string]}
    assert ty(arm0) == @string

    for ok <- [
          @box <>
            "def G.f(b : G.Box<Int>) : Int do case b do G.Box.Full(n) -> n + 1\n G.Box.Empty -> 0 end end",
          @box <>
            "def G.f(b : G.Box<G.Box<Int>>) : Int do case b do G.Box.Full(G.Box.Full(n)) -> n + 1\n " <>
            "G.Box.Full(_) -> 0\n G.Box.Empty -> 0 end end",
          """
          deftype G.Pair<K, V> do Both(K, V) | Neither end
          def G.f(p : G.Pair<String, Int>) : Int do case p do
            G.Pair.Both(k, v) -> v + String.length(k)
            G.Pair.Neither -> 0
          end end
          """,
          "def A.f(o : Option<Int>) : Int do case o do Option.Some(x) -> x + 1\n Option.None -> 0 end end"
        ] do
      assert ty(checks(ok)) == @int, ok
    end

    for {wrong, quoted} <- [
          {@box <>
             "def G.f(b : G.Box<String>) : Int do case b do G.Box.Full(n) -> n + 1\n G.Box.Empty -> 0 end end",
           "n"},
          {@box <>
             "def G.f(b : G.Box<G.Box<String>>) : Int do case b do G.Box.Full(G.Box.Full(n)) -> n + 1\n " <>
             "G.Box.Full(_) -> 0\n G.Box.Empty -> 0 end end", "n"},
          {"def A.f(o : Option<String>) : Int do case o do Option.Some(x) -> x + 1\n Option.None -> 0 end end",
           "x"}
        ] do
      err = first_error(wrong)

      assert {err.code, err.message} ==
               {"mismatch", "type mismatch: expected Int, got String in `#{quoted}`"},
             wrong
    end
  end

  test "a hostile pattern binder is refused" do
    for {src, name} <- [
          {"deftype A.T do B(Int) | C end\ndef T.f(x : A.T) : Int do case x do A.T.B(prototype) -> 1\n A.T.C -> 2 end end",
           "prototype"},
          {"def T.f(x : Int) : Int do case x do prototype -> 1 end end", "prototype"},
          {"def T.f(x : Int) : Int do case x do __proto__ -> 1 end end", "__proto__"}
        ] do
      assert found(src) == [{"bad-name", "`#{name}` is not a valid identifier"}], src
    end
  end

  test "a pattern that does not fit its scrutinee is a bad pattern" do
    t = "deftype A.T do X(Int) | Y end\n"

    for {src, message} <- [
          {t <>
             "deftype A.U do X end\ndef A.f(t : A.T) : Int do case t do A.U.X -> 1\n _ -> 2 end end",
           "pattern `A.U.X` does not belong to `A.T`"},
          {t <> "def A.f(t : A.T) : Int do case t do X -> 1\n _ -> 2 end end",
           "pattern `X` does not belong to `A.T`"},
          {t <> "def A.f(t : A.T) : Int do case t do A.T.Z -> 1\n _ -> 2 end end",
           "`A.T` has no variant `Z`"},
          {t <> "def A.f(t : A.T) : Int do case t do A.T.X -> 1\n _ -> 2 end end",
           "pattern `A.T.X` expects 1 argument(s), got 0"},
          {t <> "def A.f(t : A.T) : Int do case t do A.T.Y(n) -> 1\n _ -> 2 end end",
           "pattern `A.T.Y` expects 0 argument(s), got 1"},
          {@wrap <>
             "def F.f(o : Out.T) : Int do case o do Out.T.Wrap(Out.T.Wrap(x)) -> 1\n _ -> 2 end end",
           "pattern `Out.T.Wrap` does not belong to `In.T`"}
        ] do
      err = first_error(src)
      assert {err.code, err.message} == {"bad-pattern", message}, src
    end

    assert found(t <> "def A.f(t : A.T) : Int do case t do A.T.Z -> 1\n A.T.X(n) -> n end end") ==
             [
               {"bad-pattern", "`A.T` has no variant `Z`"},
               {"non-exhaustive", "case on `A.T` is not exhaustive — missing: A.T.Y"}
             ]
  end

  test "a case on a scalar needs an irrefutable arm" do
    for wanting <- [
          "def A.f(n : Int) : Int do case n do 1 -> 1\n 2 -> 2 end end",
          "def A.f(b : Bool) : Int do case b do true -> 1\n false -> 2 end end"
        ] do
      err = first_error(wanting)

      assert {err.code, err.message} ==
               {"non-exhaustive", "case on a scalar needs a final `_` or binder arm"}
    end

    for ok <- [
          "def A.f(n : Int) : Int do case n do _ -> 1\n 2 -> 2 end end",
          ~S|def A.f(s : String) : Int do case s do "a" -> 1| <>
            "\n other -> String.length(other) end end",
          "def A.f(u : Uuid) : Int do case u do x -> 1 end end"
        ] do
      assert ty(checks(ok)) == @int, ok
    end

    for {src, message} <- [
          {~S|def A.f(n : Int) : Int do case n do "a" -> 1| <> "\n _ -> 2 end end",
           ~S|type mismatch: expected Int, got String in `"a"`|},
          {"deftype A.T do X | Y end\ndef A.f(t : A.T) : Int do case t do 1 -> 1\n _ -> 2 end end",
           "type mismatch: expected A.T, got Int in `1`"}
        ] do
      err = first_error(src)
      assert {err.code, err.message} == {"mismatch", message}, src
    end
  end

  test "a case scrutinee must be a variant type, a scalar or a tuple" do
    must = "case scrutinee must be a variant type, a scalar or a tuple, got"

    for {src, expected} <- [
          {"def A.f(xs : List<Int>) : Int do case xs do _ -> 1 end end",
           ["#{must} List<Int> in `xs`"]},
          {"defmodel A.M do x : Int end\ndef A.f(m : A.M) : Int do case m do _ -> 1 end end",
           ["#{must} A.M in `m`"]},
          {"def A.f(xs : List<Int>) : Int do case xs do 1 -> 1\n _ -> 2 end end",
           ["#{must} List<Int> in `xs`", "type mismatch: expected List<Int>, got Int in `1`"]}
        ] do
      assert found(src) == Enum.map(expected, &{"mismatch", &1}), src
    end

    assert found("def A.f() : Int do case nope do _ -> 1 end end") == [
             {"unbound", "unbound symbol `nope`"},
             {"mismatch", "#{must} ?0 in `nope`"}
           ]
  end

  test "a case's arms share one type and keep their binders to themselves" do
    t = "deftype A.T do X(Int) | Y end\n"

    typed =
      checks(
        t <> "def A.f(t : A.T) : List<Int> do case t do A.T.X(_) -> []\n A.T.Y -> [1] end end"
      )

    assert ty(typed) == {:applied, "List", [@int]}

    for {src, code, message} <- [
          {t <>
             ~S|def A.f(t : A.T) : Int do case t do A.T.X(_) -> 1| <>
             "\n" <> ~S| A.T.Y -> "no" end end|, "mismatch",
           ~S|type mismatch: expected Int, got String in `"no"`|},
          {t <> "def A.f(t : A.T) : Int do case t do A.T.X(k) -> k\n A.T.Y -> k end end",
           "unbound", "unbound symbol `k`"},
          {t <> "def A.f(t : A.T) : Int do case t do end end", "non-exhaustive",
           "case on `A.T` is not exhaustive — missing: A.T.X, A.T.Y"}
        ] do
      err = first_error(src)
      assert {err.code, err.message} == {code, message}, src
    end
  end

  test "a case depends on every type its patterns are checked against" do
    deps = &sorted(last_checked(&1).deps)
    assert deps.(levels("L.A.Top(L.B.Mid(L.C.P, n)) -> n")) == ["L.A", "L.B", "L.C"]
    assert deps.(levels("L.A.Top(L.B.Mid(c, n)) -> n")) == ["L.A", "L.B"]

    assert deps.(@wrap <> "def F.f(o : Out.T) : Int do case o do Out.T.Wrap(inner) -> 1 end end") ==
             ["Out.T"]

    assert deps.("""
           deftype In.T do A | B end
           def F.g() : In.T do In.T.A end
           def F.f() : Int do case F.g() do In.T.A -> 1
            In.T.B -> 2 end end
           """) == ["F.g", "In.T"]

    assert deps.("def A.f(n : Int) : Int do case n do _ -> 1 end end") == ["Int"]
  end

  test "a pattern binds each name once" do
    t = """
    deftype A.T do X(Int) | P(Int, Int) | Y end
    deftype A.O do Q(A.T, Int) | Z end
    """

    for src <- [
          t <> "def A.f(t : A.T) : Int do case t do A.T.P(x, x) -> x\n _ -> 2 end end",
          t <> "def A.f(o : A.O) : Int do case o do A.O.Q(A.T.X(x), x) -> x\n _ -> 2 end end"
        ] do
      assert found(src) == [{"bad-name", "`x` is already bound in this pattern"}], src
    end

    invalid = {"bad-name", "`prototype` is not a valid identifier"}
    repeated = {"bad-name", "`prototype` is already bound in this pattern"}

    assert found(
             t <>
               "def A.f(t : A.T) : Int do case t do A.T.P(prototype, prototype) -> 1\n _ -> 2 end end"
           ) == [invalid, invalid, repeated]

    later = """
    deftype M.Msg do Inc | Dec | Set(Int) end
    def M.handle(m : M.Msg) : Int do 1 end
    deftype G.Two<K> do Both(K, Int) | No end
    def A.f() : Int do case G.Two.No do
      G.Two.Both(M.Msg.Set(x), x) -> x
      G.Two.Both(m, _) -> M.handle(m)
      _ -> 0
    end end
    """

    assert found(later) == [{"bad-name", "`x` is already bound in this pattern"}]

    for ok <- [
          t <>
            "def A.f(t : A.T) : Int do case t do A.T.P(x, _) -> x\n A.T.X(x) -> x\n A.T.Y -> 0 end end",
          "def A.f(n : Int) : Int do case n do n -> n end end"
        ] do
      assert ty(checks(ok)) == @int, ok
    end
  end

  test "a variant pattern matches only a variant type" do
    t = "deftype A.T do X(Int) | L(List<Int>) | Y end\n"
    only = "only a deftype's values have variants — match it with"

    for {src, message} <- [
          {t <> "def A.f(n : Int) : Int do case n do A.T.X -> 1\n _ -> 2 end end",
           "pattern `A.T.X` cannot match `n`, of type Int: #{only} a literal, `_` or a binder"},
          {t <> "def A.f(t : A.T) : Int do case t do A.T.X(Nope.Z.W) -> 1\n _ -> 2 end end",
           "pattern `Nope.Z.W` cannot match argument 1 of `A.T.X`, of type Int: #{only} a literal, `_` or a binder"},
          {t <> "def A.f(t : A.T) : Int do case t do A.T.L(A.T.Y) -> 1\n _ -> 2 end end",
           "pattern `A.T.Y` cannot match argument 1 of `A.T.L`, of type List<Int>: #{only} `_` or a binder"}
        ] do
      assert found(src) == [{"bad-pattern", message}], src
    end

    long = String.duplicate("x", 300)

    err =
      first_error(
        t <> ~s|def A.f() : Int do case String.length("#{long}") do A.T.Y -> 1\n _ -> 2 end end|
      )

    assert err.code == "bad-pattern"
    assert err.message =~ ~S|String.length("xxx|
    refute err.message =~ long
    assert err.message =~ "…`, of type Int"

    assert found(
             @box <>
               t <>
               "def A.f() : Int do case G.Box.Empty do G.Box.Full(A.T.Y) -> 1\n _ -> 2 end end"
           ) == [{"cannot-infer", "cannot infer the type of `G.Box.Empty`"}]

    src = "def A.f(xs : List<Int>) : Int do case xs do A.T.X -> 1\n _ -> 2 end end"
    assert Enum.map(errors(src), & &1.code) == ["mismatch"]
  end

  defp parsed(arms) do
    msg() <>
      "def M.f(s : String) : Int do\n  case JSON.parse(s) do\n    #{Enum.join(arms, "\n    ")}\n  end\nend"
  end

  test "a nested pattern whose type is known only later is checked once it is" do
    inc_then = &parsed(["Result.Ok(M.Msg.Inc) -> 1", &1, "Result.Err(e) -> 0"])
    then_inc = &parsed([&1, "Result.Ok(M.Msg.Inc) -> 1", "Result.Err(e) -> 0"])

    for src <- [
          inc_then.("Result.Ok(m) -> M.handle(m)"),
          then_inc.("Result.Ok(m) -> M.handle(m)")
        ] do
      assert ty(checks(src)) == @int, src
      assert sorted(last_checked(src).deps) == ["JSON.parse", "M.Msg", "M.handle", "Result"], src
    end

    across_cases = fn first, second ->
      msg() <>
        "def M.f(s : String) : Int do\n  x = JSON.parse(s)\n  " <>
        "y = case x do\n    #{first}\n    _ -> 0\n  end\n  " <>
        "case x do\n    #{second}\n    _ -> 0\n  end\nend"
    end

    not_int =
      "pattern `M.Msg.Inc` cannot match argument 1 of `Result.Ok`, of type Int: only a deftype's values " <>
        "have variants — match it with a literal, `_` or a binder"

    for {sources, code, message} <- [
          {[inc_then.("Result.Ok(m) -> N.take(m)"), then_inc.("Result.Ok(m) -> N.take(m)")],
           "bad-pattern", "pattern `M.Msg.Inc` does not belong to `N.Other`"},
          {[
             parsed([
               "Result.Ok(M.Msg.Set(prototype)) -> 1",
               "Result.Ok(m) -> M.handle(m)",
               "Result.Err(e) -> 0"
             ]),
             parsed([
               "Result.Ok(m) -> M.handle(m)",
               "Result.Ok(M.Msg.Set(prototype)) -> 1",
               "Result.Err(e) -> 0"
             ])
           ], "bad-name", "`prototype` is not a valid identifier"},
          {[inc_then.("Result.Ok(m) -> m + 1"), then_inc.("Result.Ok(m) -> m + 1")],
           "bad-pattern", not_int},
          {[
             across_cases.("Result.Ok(M.Msg.Inc) -> 1", "Result.Ok(m) -> m + y"),
             across_cases.("Result.Ok(m) -> m", "Result.Ok(M.Msg.Inc) -> y")
           ], "bad-pattern", not_int}
        ],
        src <- sources do
      assert found(src) == [{code, message}], src
    end
  end

  test "the declared return type settles a type before waiting patterns are checked" do
    program = fn ret ->
      """
      deftype M.Msg do Inc | Dec end
      deftype N.Other do Z end
      def A.f(s : String) : Result<#{ret}, String> do
        x = JSON.parse(s)
        n = case x do
          Result.Ok(M.Msg.Inc) -> 1
          _ -> 0
        end
        x
      end
      """
    end

    checked = last_checked(program.("M.Msg"))
    assert {:ok, _} = checked.result
    assert sorted(checked.deps) == ["JSON.parse", "M.Msg", "Result"]

    assert found(program.("N.Other")) == [
             {"bad-pattern", "pattern `M.Msg.Inc` does not belong to `N.Other`"}
           ]
  end

  test "a waiting pattern may settle a type TS leaves open" do
    program = fn [a, b] ->
      "def G.f(s : String) : Int do case JSON.parse(s) do\n  #{a}\n  #{b}\n  _ -> 0\nend end"
    end

    literal = "Result.Ok(Option.Some(5)) -> 1"
    holder = "Result.Ok(o) -> List.length(List.filter_map([1], fn (x : Int) -> o end))"

    for src <- [program.([literal, holder]), program.([holder, literal])] do
      assert ty(checks(src)) == @int, src
    end
  end

  # ---------- Rust-only: declarations ----------

  test "a test body whose type stays open quotes the whole block" do
    assert found("deftest A.t do [] end") == [
             {"cannot-infer", "cannot infer the type of `do\n  []\nend`"}
           ]

    assert found("deftest A.t do x = []\n 1 end") == [
             {"cannot-infer", "cannot infer the type of `[]`"}
           ]

    for ok <- [
          "deftest A.t do always(1 == 1) end",
          "deftest A.t do x = 1\n always(x == 1)\n x end"
        ] do
      assert {:ok, _} = last_checked(ok).result, ok
    end
  end

  test "a def's value is checked against its return type" do
    for src <- ["def A.f() : Int do\n  x = 1\n  \"s\"\nend", ~S|def A.f() : Int do "s" end|] do
      assert found(src) == [{"mismatch", ~S|type mismatch: expected Int, got String in `"s"`|}]
    end

    checked = last_checked("def A.f(x : A.Nope) : A.Gone do 1 end")
    {:error, errs} = checked.result

    assert Enum.map(errs, &{&1.code, &1.message}) == [
             {"unbound", "unknown type `A.Nope`"},
             {"unbound", "unknown type `A.Gone`"},
             {"mismatch", "type mismatch: expected A.Gone, got Int in `1`"}
           ]

    assert checked.deps == MapSet.new(["A.Gone", "A.Nope"])
  end

  test "a def's parameters are checked once and its body may shadow them" do
    assert found("def A.f(prototype : Int) : Int do prototype end") == [
             {"bad-name", "`prototype` is not a valid identifier"}
           ]

    assert ty(checks("def A.f(x : Int) : Int do\n  x = 2\n  x\nend")) == @int
  end

  test "model fields and variant arguments resolve and are data" do
    function = fn field, t ->
      {"invalid-model-field",
       "model field `#{field}` cannot hold a function type `#{t}` — models must persist"}
    end

    unknown = &{"unbound", "unknown type `#{&1}`"}

    for {src, expected} <- [
          {"defmodel A.M do f : (Int -> Int)\n g : A.Nope end",
           [function.("f", "(Int -> Int)"), unknown.("A.Nope")]},
          {"deftype A.T<X> do F((X -> Int)) | G(List<Y>) | H(X, Cmd<X>) end",
           [
             function.("F", "(X -> Int)"),
             unknown.("Y"),
             {"invalid-model-field",
              "model field `H` cannot hold `Cmd<X>` — effects are not data to store"}
           ]}
        ] do
      assert found(src) == expected, src
    end

    all_ok(
      "deftype A.T<X> do F(X) | G(List<X>) | H(Option<A.T<X>>) end\ndefmodel A.M do t : A.T<Int> end"
    )
  end

  test "a program is checked declaration by declaration against every signature" do
    all_ok("def A.f() : Int do A.g() end\ndef A.g() : Int do 1 end")
    results = check_all(~s|def A.f() : Int do "x" end\ndef A.g() : Int do 1 end|)
    assert {:error, _} = results["A.f"].result
    assert {:ok, _} = results["A.g"].result
  end

  # ---------- Rust-only: the final review's fixes ----------

  defp doubling(n, map?) do
    lines =
      for i <- 1..n//1 do
        p = i - 1
        value = if map?, do: "%{x#{p} => x#{p}}", else: "(x#{p}, x#{p})"
        "  x#{i} = #{value}\n"
      end

    "def A.f() : Int do\n  x0 = 1\n" <> Enum.join(lines) <> "  1\nend"
  end

  @tag :perf
  test "a type that doubles at every line stops the check at once" do
    for {map?, quoted} <- [{false, "(x12, x12)"}, {true, "%{x12 => x12}"}] do
      decls = parse(doubling(30, map?))
      {us, checked} = :timer.tc(fn -> Check.program(decls, Stdlib.signatures()) end)
      {:error, errs} = checked["A.f"].result

      assert Enum.map(errs, &{&1.code, &1.message}) == [
               {"type-too-large", "the type of `#{quoted}` is too large: more than 10000 nodes"}
             ]

      assert us < 2_000_000
    end
  end

  test "a type just under the size limit checks" do
    for map? <- [false, true] do
      all_ok(doubling(12, map?))
      assert length(errors(doubling(13, map?))) == 1
    end
  end

  test "copies of a large type stop the check" do
    copies = List.duplicate("x12", 3000) |> Enum.join(", ")
    src = String.replace(doubling(12, false), "  1\nend", "  y = [#{copies}]\n  1\nend")
    [err] = errors(src)
    assert err.code == "type-too-large"

    assert String.starts_with?(
             err.message,
             "the types of this declaration are too large for its size: at `x12`"
           )
  end

  test "a large type is cut in a message" do
    src = String.replace(doubling(10, false), "  1\nend", "  x10\nend")
    t = Enum.reduce(1..10, "Int", fn _, t -> "(#{t}, #{t})" end)
    cut = String.slice(t, 0, 200) <> "…"
    assert found(src) == [{"mismatch", "type mismatch: expected Int, got #{cut} in `x10`"}]
  end

  @tag timeout: 120_000
  @tag :perf
  test "a deep failing nest is quoted cheaply" do
    inner = "[" <> Enum.join(List.duplicate("1", 1_000_000), ", ") <> "]"
    nest = Enum.reduce(1..250, inner, fn _, n -> ~S|["s", | <> n <> "]" end)
    src = "def A.f() : Int do\n  x = #{nest}\n  1\nend"
    decls = parse(src)
    {us, checked} = :timer.tc(fn -> Check.program(decls, Stdlib.signatures()) end)
    {:error, errs} = checked["A.f"].result
    assert length(errs) == 250
    ones = String.duplicate("1, ", 67) |> String.slice(0, 199)
    assert hd(errs).message == "type mismatch: expected String, got List<Int> in `[#{ones}…`"

    for e <- errs do
      assert e.code == "mismatch"
      assert String.length(e.message) < 300 and String.ends_with?(e.message, "…`")
    end

    assert us < 15_000_000
  end

  test "every stdlib root is reserved" do
    for {src, name, root} <- [
          {"deftype Result<T, E> do Ok(T) end", "Result", "Result"},
          {~S|def JSON.stringify(x : Int) : String do "" end|, "JSON.stringify", "JSON"},
          {"def Tx.insert(x : Int) : Int do x end", "Tx.insert", "Tx"},
          {"defmodel Uuid.M do x : Int end", "Uuid.M", "Uuid"}
        ] do
      err = first_error(src)

      assert {err.code, err.message} ==
               {"bad-name",
                "`#{name}` is in the reserved `#{root}` namespace — pick another name"},
             src
    end
  end

  defp bad_name(message), do: [{"bad-name", message}]

  test "names declared twice are refused" do
    assert found("def A.f(x : Int, x : Int) : Int do x end") ==
             bad_name("`x` is already a parameter of `A.f`")

    assert found("def A.f() : Int do List.foldl([1], 0, fn (x : Int, x : Int) -> x end) end") ==
             bad_name("`x` is already a parameter of this fn")

    assert found("defmodel A.M do x : Int\n x : String end") ==
             bad_name("`x` is already a field of `A.M`")

    assert found(
             "deftype A.T do X | X(Int) end\ndef A.f(t : A.T) : Int do case t do A.T.X -> 1 end end"
           ) ==
             bad_name("`X` is already a variant of `A.T`")

    assert found("deftype A.T<X, X> do F(X) end") ==
             bad_name("`X` is already a parameter of `A.T`")
  end

  test "a field set twice in a construction or an update is refused" do
    twice = [{"extra-field", "`%A.M{…}` sets field `x` more than once"}]
    assert found("defmodel A.M do x : Int end\ndef A.f() : A.M do %A.M{x: 1, x: 2} end") == twice

    assert found(
             "defmodel A.M do x : Int end\ndef A.f(m : A.M) : A.M do %A.M{m | x: 1, x: 2} end"
           ) ==
             twice
  end

  test "a declaration name needs a module" do
    for {src, name} <- [
          {"def foo() : Int do 1 end", "foo"},
          {"defmodel M do x : Int end", "M"},
          {"deftype T do X end", "T"},
          {"deftest it do 1 end", "it"}
        ] do
      assert found(src) ==
               bad_name(
                 "`#{name}` has no module — every name is qualified: name it `Mod.#{name}`"
               ),
             src
    end
  end

  test "every declaration kind follows the naming convention" do
    for ok <- [
          "def A.f(x : Int) : Int do x end",
          "deftest A.it do 1 end",
          "defmodel A.M do x : Int end",
          "deftype A.T do X | Y(Int) end"
        ] do
      assert {:ok, _} = last_checked(ok).result, ok
    end

    for bad <- [
          "deftest A.It do 1 end",
          "defmodel A.m do x : Int end",
          "def A.f(prototype : Int) : Int do 1 end"
        ] do
      assert codes(last_checked(bad)) == ["bad-name"], bad
    end
  end

  # ---------- decl.rs unit tests ----------

  defp field_codes(src) do
    [{:defmodel, _, [_, fields]}] = parse(src)

    fields
    |> Enum.reduce(Ctx.new(%{}), fn {name, t}, ctx -> Decl.forbid_in_model_field(ctx, t, name) end)
    |> Ctx.errors()
    |> Enum.map(& &1.code)
  end

  test "a function or an effect is refused however deep in a field" do
    for field <- [
          "h : Html<Int>",
          "c : Cmd",
          "l : List<Cmd<Int>>",
          "t : (Int, (Int -> Int))",
          "m : Map<String, Html<A.Msg>>"
        ] do
      assert field_codes("defmodel A.M do #{field} end") == ["invalid-model-field"], field
    end

    for field <- ["n : Int", "o : Option<List<String>>", "p : (Int, String)", "r : A.Other"] do
      assert field_codes("defmodel A.M do #{field} end") == [], field
    end
  end

  test "an identifier is plain and never one codegen refuses" do
    for bad <- ["__proto__", "constructor", "prototype", "", "1x", "a-b", "é"] do
      assert Enum.map(Ctx.errors(Ctx.check_ident(Ctx.new(%{}), bad)), & &1.code) == ["bad-name"],
             bad
    end

    for good <- ["x", "_x1", "Board", "snake_case"] do
      assert Ctx.errors(Ctx.check_ident(Ctx.new(%{}), good)) == [], good
    end
  end

  # ---------- check_expr ----------

  test "check_expr types and resolves a call" do
    {:ok, expr} = Parser.expr("List.map([1], fn (x : Int) -> x + 1 end)")
    checked = Check.expr(expr, Stdlib.signatures())
    {:ok, typed} = checked.result
    assert ty(typed) == {:applied, "List", [@int]}
    assert res(typed) == {:def, "List.map"}
    assert {:call, _, ["List.map", _]} = typed
  end

  test "check_expr reports an unbound name as TS does" do
    {:ok, expr} = Parser.expr("Nowhere.at_all(1)")
    {:error, [err | _]} = Check.expr(expr, Stdlib.signatures()).result
    assert {err.code, err.message} == {"unbound", "unbound symbol `Nowhere.at_all`"}
  end

  test "check_expr records dependencies" do
    {:ok, expr} = Parser.expr("String.length(String.from_int(1))")
    checked = Check.expr(expr, Stdlib.signatures())
    assert {:ok, _} = checked.result
    assert checked.deps == MapSet.new(["String.length", "String.from_int"])
  end

  test "on success, deps is a superset of Extract.deps" do
    src = """
    deftype M.T do A | B(Int) end
    defmodel M.R do n : Int end
    def M.g(t : M.T) : M.R do case t do M.T.A -> %M.R{n: 0}
     M.T.B(k) -> %M.R{n: k} end end
    def M.f(r : M.R) : Int do List.length([M.g(M.T.A)]) + r.n end
    """

    for d <- parse(src), checked = check_all(src)[Kinoko.Lang.Ast.name(d)] do
      assert {:ok, _} = checked.result
      assert MapSet.subset?(Extract.deps(d), checked.deps)
    end
  end

  # ---------- typecheck.test.ts "yabu corpus typechecks" ----------

  for file <- ~w(counter notes split todo) do
    test "#{file}.yabu fully checks" do
      all_ok(YabuOracle.corpus_source(unquote(file) <> ".yabu"))
    end
  end

  # ---------- typecheck.test.ts "defapp validation" ----------

  # TS writes bare `Html`; here `Html` carries the app's `Msg`.
  @app_base """
  defmodel C.Model do n : Int end
  deftype C.Msg do Inc end
  def C.init() : (C.Model, Cmd<C.Msg>) do (%C.Model{n: 0}, Cmd.none()) end
  def C.view(model : C.Model) : Html<C.Msg> do <div>{model.n}</div> end
  """

  test "defapp accepts the full shape" do
    all_ok(
      @app_base <>
        """
        def C.update(msg : C.Msg, model : C.Model) : (C.Model, Cmd<C.Msg>) do (model, Cmd.none()) end
        defapp C
        """
    )
  end

  test "defapp rejects update returning a bare model" do
    src =
      @app_base <>
        "def C.update(msg : C.Msg, model : C.Model) : C.Model do model end\ndefapp C"

    {:error, [e | _]} = check_all(src)["C"].result
    assert e.code == "bad-app-shape"
    assert e.message =~ "C.update"
  end

  test "defapp rejects a missing view" do
    src = """
    defmodel D.Model do n : Int end
    deftype D.Msg do Inc end
    def D.init() : (D.Model, Cmd<D.Msg>) do (%D.Model{n: 0}, Cmd.none()) end
    def D.update(msg : D.Msg, model : D.Model) : (D.Model, Cmd<D.Msg>) do (model, Cmd.none()) end
    defapp D
    """

    {:error, [e | _]} = check_all(src)["D"].result
    assert e.message =~ "D.view"
  end

  test "an app reports every part missing or misshapen" do
    checked =
      last_checked("""
      deftype D.Model do X end
      defmodel D.Msg do n : Int end
      deftest D.init do 1 end
      defapp D
      """)

    {:error, errs} = checked.result

    assert Enum.map(errs, &{&1.code, &1.message}) ==
             Enum.map(
               [
                 "app `D` requires `D.update`, which is not defined",
                 "app `D` requires `D.view`, which is not defined",
                 "`D.Model` must be a defmodel",
                 "`D.Msg` must be a deftype",
                 "`D.init` must be a def"
               ],
               &{"bad-app-shape", &1}
             )

    assert sorted(checked.deps) == ["D.Model", "D.Msg", "D.init", "D.update", "D.view"]

    src =
      @app_base <>
        "def C.update(msg : C.Msg, model : C.Model) : C.Model do model end\ndefapp C"

    {:error, errs} = last_checked(src).result

    assert Enum.map(errs, &{&1.code, &1.message}) == [
             {"bad-app-shape",
              "`C.update` must have type (C.Msg, C.Model -> (C.Model, Cmd<C.Msg>)), got (C.Msg, C.Model -> C.Model)"}
           ]
  end

  # ---------- typecheck.test.ts "views and events" ----------

  test "on-click requires a variant value" do
    src =
      "deftype A.Msg do Go end\ndef A.v() : Html<A.Msg> do <button on-click={42}>x</button> end"

    assert first_error(src).code == "bad-event"
  end

  test "on-change requires a 1-arity String constructor" do
    all_ok(
      "deftype E.Msg do Set(String) end\ndef E.v() : Html<E.Msg> do <input on-change={E.Msg.Set} /> end"
    )

    bad =
      "deftype E.Msg do Set(Int, Int) end\ndef E.v() : Html<E.Msg> do <input on-change={E.Msg.Set} /> end"

    assert first_error(bad).code == "bad-event"
  end

  test "on-change takes only an unapplied one-argument String constructor" do
    msg = """
    deftype E.Msg do Set(String) | Num(Int) | Go end
    def E.set(s : String) : E.Msg do E.Msg.Set(s) end
    """

    needs =
      &{"bad-event", "on-change needs an unapplied 1-argument String constructor, got `#{&1}`"}

    for {handler, expected} <- [
          {"fn (s : String) -> E.Msg.Set(s) end",
           [needs.("fn (s : String) -> E.Msg.Set(s) end")]},
          {"E.set", [needs.("E.set")]},
          {"E.Msg.Go", [needs.("E.Msg.Go")]},
          {"E.Msg.Num",
           [
             {"mismatch", "type mismatch: expected String, got Int in `E.Msg.Num`"},
             needs.("E.Msg.Num")
           ]}
        ] do
      src = msg <> "def E.v() : Html<E.Msg> do <input on-change={#{handler}} /> end"
      assert found(src) == expected, handler
    end

    # The constructor is attached as one used without its arguments.
    typed = all_ok(msg <> "def E.v() : Html<E.Msg> do <input on-change={E.Msg.Set} /> end")
    {:def, _, [_, _, _, {:block, _, [_, {:jsx, _, [_, [attr | _], _]}]}]} = typed["E.v"]
    {:event, "change", handler} = attr
    assert res(handler) == {:ctor_ref, "E.Msg", "Set", 1}
    assert ty(handler) == {:arrow, [@string], {:named, "E.Msg"}}
  end

  test "any other event takes a value of a deftype" do
    msg = "deftype E.Msg do Set(String) | Go end\n"
    src = msg <> "def E.v() : Html<E.Msg> do <input on-click={E.Msg.Set} /> end"

    assert found(src) == [
             {"bad-event",
              "on-click needs a message value (a variant), got (String -> E.Msg) in `E.Msg.Set`"}
           ]

    # The type is a dependency, whatever it is.
    for handler <- ["E.Msg.Go", ~S|E.Msg.Set("x")|] do
      checked =
        last_checked(
          msg <> "def E.v() : Html<E.Msg> do <button on-click={#{handler}}>x</button> end"
        )

      assert {:ok, _} = checked.result, handler
      assert sorted(checked.deps) == ["E.Msg"], handler
    end

    deps =
      last_checked(
        "deftype A.Msg do Go end\ndef A.v() : Html<A.Msg> do <button on-click={42}>x</button> end"
      ).deps

    assert sorted(deps) == ["A.Msg", "Int"]
  end

  test "JSX attributes hold scalars and children Html, text or numbers" do
    msg = "deftype E.Msg do Go end\n"

    typed =
      checks(
        msg <>
          """
          def E.v(b : Bool, u : Uuid) : Html<E.Msg> do
            <div class="a" id={1} title={"t"} hidden={b} key={u}>
              x {"y"} {2}
              <p>{List.map([1], fn (x : Int) -> <i>{x}</i> end)}</p>
            </div>
          end
          """
      )

    assert ty(typed) == {:applied, "Html", [{:named, "E.Msg"}]}

    child = "JSX child must be Html, String, Int, or List<Html>, got"

    for {src, message} <- [
          {"def E.v(xs : List<Int>) : Html<E.Msg> do <input value={xs} /> end",
           "attribute `value` must be a scalar, got List<Int> in `xs`"},
          {"def E.v(xs : List<Int>) : Html<E.Msg> do <div>{xs}</div> end",
           "#{child} List<Int> in `xs`"},
          {"def E.v(b : Bool) : Html<E.Msg> do <div><p>{b}</p></div> end", "#{child} Bool in `b`"}
        ] do
      assert found(msg <> src) == [{"mismatch", message}], src
    end

    # An open type is taken as an `Html`: what `JSON.parse` gave, here.
    typed =
      checks(
        msg <>
          """
          def E.v(s : String) : Html<E.Msg> do case JSON.parse(s) do
            Result.Ok(v) -> <div>{v}</div>
            Result.Err(e) -> <p>{e}</p>
          end end
          """
      )

    {:case, _, [scrutinee, _]} = typed
    html = {:applied, "Html", [{:named, "E.Msg"}]}
    assert ty(scrutinee) == {:applied, "Result", [html, @string]}
  end

  # ---------- typecheck.test.ts "unbound hints" ----------

  test "a model called positionally names the construction syntax" do
    m = probe("Game.Board(1, 2)")
    assert m =~ "is a model, not a function"
    assert m =~ "%Game.Board{moves: …, winner: …}"
  end

  test "the invented constructor family points at the model it hangs off" do
    for guess <- ~w|Game.Board.new(1) Game.Board.create(1) Game.Board.mk(1) Game.Board.insert(1)| do
      assert probe(guess) =~ "%Game.Board{moves: …, winner: …}", guess
    end
  end

  test "id is never offered: the store mints it" do
    refute probe("Game.Board(1, 2)") =~ "id:"
  end

  test "the update form is shown too, since it is not guessable either" do
    assert probe("Game.Board(1, 2)") =~ "%Game.Board{row | moves: …}"
  end

  test "a bare name reports the qualified form, because every name is qualified" do
    m = probe("Board(1, 2)")
    assert m =~ "`Board` is not in scope"
    assert m =~ "Game.Board"
  end

  test "a wrong variant lists the real ones instead of denying the type" do
    m = probe("Game.Turn.Maybe")
    assert m =~ "is a type, not a value"
    assert m =~ "`Game.Turn.X`"
    assert m =~ "`Game.Turn.O`"
  end

  test "a def reached by the wrong name still says where it lives" do
    assert probe("other(Game.Turn.X)") =~ "Game.other"
  end

  test "a wrong case is the same mistake, so it gets the same answer" do
    for guess <- ["Game.board(1, 2)", "board(1, 2)"] do
      assert probe(guess) =~ "%Game.Board{moves: …, winner: …}", guess
    end
  end

  test "a missing member answers with the namespace that does exist" do
    m = probe("List.fold(1)")
    assert m =~ "there is no `List.fold`"
    assert m =~ "`List.foldl`"
    refute m =~ "`List.fold`,"
  end

  test "a missing effect answers with the effects there are" do
    assert probe("Cmd.store.bogus(1)") =~ "`Cmd.store.insert`"
  end

  test "a field of a capitalised local suggests parenthesising it" do
    err = first_error("defmodel A.M do x : Int end\ndef A.f(M : A.M) : Int do M.x end")
    assert err.code == "unbound"
    assert err.message =~ "`(M).x`"
    assert ty(checks("defmodel A.M do x : Int end\ndef A.f(M : A.M) : Int do (M).x end")) == @int
  end

  test "the local field hint yields to TS's own hints" do
    probe_with_local = fn body ->
      first_error(@game <> "def Game.probe(Game : Int) : Int do #{body} end").message
    end

    for {body, ts_says} <- [
          {"Game.Board.moves",
           "`Game.Board.moves` is not in scope — `Game.Board` is a model, not a function"},
          {"Game.board",
           "`Game.board` is not in scope — `Game.Board` is a model, not a function"},
          {"Game.Turn.Maybe",
           "`Game.Turn.Maybe` is not in scope — `Game.Turn` is a type, not a value"},
          {"Game.x",
           "there is no `Game.x` — `Game` has `Game.Board`, `Game.Turn`, `Game.other`, `Game.probe`"}
        ] do
      m = probe_with_local.(body)

      assert String.starts_with?(m, ts_says) and not String.contains?(m, "(Game)"),
             "#{body}: #{m}"
    end
  end

  test "a case-insensitive hint prefers the stdlib in its declared order" do
    for {body, name} <- [
          {"get(1)", "`Cmd.store.get`"},
          {"list(1)", "`Cmd.store.list`"},
          {"List", "`Cmd.store.list`"},
          {"delete(1)", "`Cmd.store.delete`"},
          {"put(1)", "`Cmd.blob.put`"}
        ] do
      assert probe(body) =~ "is what you want — every name is fully qualified, so write #{name}",
             body
    end
  end

  test "a case-insensitive hint prefers the stdlib to the program's own declarations" do
    err =
      first_error(
        "def App.length(x : Int) : Int do x end\ndef App.f(xs : List<Int>) : Int do length(xs) end"
      )

    assert err.message =~ "so write `List.length`"
  end

  test "a lookup function gives the plain message: it has no whole table to hint from" do
    {:ok, [d]} = Parser.program("def Game.probe() : Int do board(1, 2) end")
    sigs = fn name -> Map.get(Stdlib.signatures(), name) end
    {:error, [e | _]} = Check.decl(d, sigs).result
    assert e.message == "unbound symbol `board`"
  end

  # ---------- Rust-only: map keys must be data ----------

  test "a map annotated with a function key is refused" do
    err = first_error("def A.f(m : Map<(Int -> Int), Int>) : Int do 0 end")
    assert err.code == "non-data-map-key"
    assert err.message =~ "map key"
  end

  test "a map literal with a function key is refused" do
    err = first_error("def A.f() : Int do m = %{fn (x : Int) -> x end => 1} \n 0 end")
    assert err.code == "non-data-map-key"
    assert err.message =~ "map key"
  end

  test "a map with a function value is still allowed" do
    checks("def A.f(m : Map<String, (Int -> Int)>) : Map<String, (Int -> Int)> do m end")
  end

  defp with_fake_make do
    Map.put(
      Stdlib.signatures(),
      "Fake.make",
      {:def, [{:var, "a"}], {:applied, "Map", [{:var, "a"}, @int]}}
    )
  end

  test "a generic call's Map result with a function key is refused" do
    [d] = parse("def A.f() : Int do\n  m = Fake.make(fn (x : Int) -> x end)\n  0\nend")
    {:error, errs} = Check.decl(d, with_fake_make()).result
    assert Enum.any?(errs, &(&1.code == "non-data-map-key")), inspect(errs)
  end

  test "a generic deftype holding a Map at a function key is refused" do
    src =
      "deftype Box.T<K, V> do B(Map<K, V>) end\ndef A.f(b : Box.T<(Int -> Int), Int>) : Int do 0 end"

    assert first_error(src).code == "non-data-map-key"
  end

  test "a recursive generic deftype holding a Map at a function key is refused" do
    src =
      "deftype Rec.T<K, V> do Node(Map<K, V>, Rec.T<K, V>) | Leaf end\ndef A.f(r : Rec.T<(Int -> Int), Int>) : Int do 0 end"

    assert first_error(src).code == "non-data-map-key"
  end

  test "a deftype the map-key rule expands is a dependency" do
    src = """
    deftype M.Inner<K> do I(K) end
    deftype M.W<K> do W(M.Inner<K>) end
    def M.c(w : M.W<(Int -> Int)>) : Int do 1 end
    """

    checked = last_checked(src)
    assert {:ok, _} = checked.result
    assert sorted(checked.deps) == ["M.Inner", "M.W"]
    broken = String.replace(src, "I(K)", "I(Map<K, Int>)")
    assert first_error(broken).code == "non-data-map-key"

    # A failed check reads on past a key that is not data.
    failed =
      last_checked(src <> "def M.d(x : (Map<(Int -> Int), Int>, M.W<Cmd<Int>>)) : Int do 1 end")

    assert {:error, _} = failed.result
    assert MapSet.member?(failed.deps, "M.Inner")
  end

  test "a recursive generic deftype holding a Map at a data key checks" do
    checks(
      "deftype Rec.T<K, V> do Node(Map<K, V>, Rec.T<K, V>) | Leaf end\ndef A.f(r : Rec.T<String, Int>) : Int do 0 end"
    )
  end

  # Every declaration of `src`, checked within `seconds` once parsed. The
  # bounds are Rust's debug-build ones: 1 s for most, 8 s for the fan and the
  # dense group (each settles a group of about 250,000 type nodes).
  defp check_all_within(src, seconds) do
    decls = parse(src)
    {micros, checked} = :timer.tc(fn -> Check.program(decls, Stdlib.signatures()) end)

    assert micros / 1_000_000 < seconds,
           "took #{micros / 1_000_000} s: #{String.slice(src, 0, 200)}"

    checked
  end

  defp failures(checked) do
    for {name, %{result: {:error, errs}}} <- Enum.sort(checked),
        do: {name, Enum.map(errs, & &1.code)}
  end

  @tag :perf
  test "a deftype that never repeats an instantiation checks quickly" do
    chain = Enum.map_join(1..40, fn i -> "deftype T.A#{i}<K> do A(T.A#{i - 1}<(K, K)>) end\n" end)

    shapes = [
      "deftype T.A<K> do A(T.A<(K, K)>) | E | M(Map<K, Int>) end",
      "deftype T.A<K> do A(T.A<T.A<K>>) | E | M(Map<K, Int>) end",
      "deftype T.A0<K> do A(Map<K, Int>) end\n#{chain}deftype T.A<K> do A(T.A40<K>) end"
    ]

    for shape <- shapes do
      data = check_all_within(shape <> "\ndef T.f(a : T.A<Int>) : Int do 1 end", 1.0)
      assert failures(data) == [], shape
      function = check_all_within(shape <> "\ndef T.f(a : T.A<(Int -> Int)>) : Int do 1 end", 1.0)
      assert codes(function["T.f"]) == ["non-data-map-key"], shape
    end

    assert failures(check_all_within("deftype T.A<K> do A(T.A<(K, K)>) | E end", 1.0)) == []
  end

  defp pad(i), do: String.pad_leading(Integer.to_string(i), 5, "0")

  @tag :perf
  test "a long chain of deftypes checks quickly" do
    chain =
      Enum.map_join(0..1998, fn i -> "deftype T.C#{pad(i)}<K> do A(T.C#{pad(i + 1)}<K>) end\n" end) <>
        "deftype T.C01999<K> do A(Map<K, Int>) end\n"

    src =
      chain <>
        "def T.f(c : T.C00000<(Int -> Int)>) : Int do 1 end\ndef T.g(c : T.C00000<Int>) : Int do 1 end"

    checked = check_all_within(src, 1.0)
    assert failures(checked) == [{"T.f", ["non-data-map-key"]}]
    assert MapSet.size(checked["T.f"].deps) == 2000
    assert checked["T.g"].deps == MapSet.new(["T.C00000"])
  end

  @tag :perf
  test "a ring of deftypes checks quickly" do
    length = 2000

    ring =
      Enum.map_join(0..(length - 1), fn i ->
        key = if i == 0, do: " | M(Map<K, Int>)", else: ""
        "deftype T.R#{pad(i)}<K> do A(T.R#{pad(rem(i + 1, length))}<K>)#{key} end\n"
      end)

    src =
      ring <>
        "def T.f(r : T.R01000<(Int -> Int)>) : Int do 1 end\ndef T.g(r : T.R01000<Int>) : Int do 1 end"

    checked = check_all_within(src, 1.0)
    assert failures(checked) == [{"T.f", ["non-data-map-key"]}]
    assert MapSet.size(checked["T.f"].deps) == length
    assert checked["T.g"].deps == MapSet.new(["T.R01000"])
  end

  @tag :perf
  test "a wide fan of deftypes checks quickly" do
    leaves = 10_000

    leaf =
      Enum.map_join(0..(leaves - 1), fn i ->
        "deftype T.L#{pad(i)}<K, V> do A(Map<K, V>) end\n"
      end)

    variants = Enum.map_join(0..(leaves - 1), " | ", fn i -> "V#{pad(i)}(T.L#{pad(i)}<K, V>)" end)

    src =
      leaf <>
        "deftype T.Z<K, V> do #{variants} end\n" <>
        "def T.f(z : T.Z<Int, (Int -> Int)>) : Int do 1 end\ndef T.g(z : T.Z<(Int -> Int), Int>) : Int do 1 end"

    checked = check_all_within(src, 8.0)
    assert failures(checked) == [{"T.g", ["non-data-map-key"]}]
    assert MapSet.size(checked["T.f"].deps) == leaves + 1
    assert MapSet.size(checked["T.g"].deps) == leaves + 1
  end

  @tag :perf
  test "a dense group of deftypes checks quickly" do
    size = 500
    name = &"T.D#{String.pad_leading(Integer.to_string(&1), 3, "0")}"
    all = Enum.map_join(0..(size - 1), ", ", &"#{name.(&1)}<K>")

    group =
      Enum.map_join(0..(size - 1), fn i ->
        key = if i == size - 1, do: " | M(Map<K, Int>)", else: ""
        "deftype #{name.(i)}<K> do A(#{all})#{key} end\n"
      end)

    src =
      group <>
        "def T.f(d : T.D000<(Int -> Int)>) : Int do 1 end\ndef T.g(d : T.D000<Int>) : Int do 1 end"

    checked = check_all_within(src, 8.0)
    assert failures(checked) == [{"T.f", ["non-data-map-key"]}]
    assert MapSet.size(checked["T.f"].deps) == size
    assert checked["T.g"].deps == MapSet.new(["T.D000"])
  end

  test "a parameter reaches a key through deftypes that hold each other" do
    types =
      "deftype T.X<K, P> do X(T.Y<K>, P) end\ndeftype T.Y<K> do Y(List<T.X<(Int, K), Int>>) | M(Map<K, Int>) end"

    err = first_error(types <> "\ndef T.f(x : T.X<(Int -> Int), Int>) : Int do 1 end")
    assert err.code == "non-data-map-key"
    checks(types <> "\ndef T.f(x : T.X<Int, (Int -> Int)>) : Int do 1 end")
  end

  test "two deftype instantiations colliding past the quote limit are each checked" do
    arg_x = "(" <> Enum.join(List.duplicate("String", 70), ", ") <> ")"
    arg_y = "(" <> Enum.join(List.duplicate("String", 69) ++ ["(Int -> Int)"], ", ") <> ")"
    d = "deftype D.T<K> do C(Map<K, Int>) end\n"
    checks(d <> "def A.f(x : D.T<#{arg_x}>) : Int do 0 end")

    assert first_error(d <> "def A.f(x : D.T<#{arg_y}>) : Int do 0 end").code ==
             "non-data-map-key"

    assert first_error(d <> "def A.f(x : (D.T<#{arg_x}>, D.T<#{arg_y}>)) : Int do 0 end").code ==
             "non-data-map-key"
  end

  test "an offending map type used many times is reported once" do
    [d] =
      parse(
        "def A.f() : Int do\n  m = Fake.make(fn (x : Int) -> x end)\n  n = m\n  o = n\n  0\nend"
      )

    {:error, errs} = Check.decl(d, with_fake_make()).result
    assert Enum.count(errs, &(&1.code == "non-data-map-key")) == 1, inspect(errs)
  end
end
