defmodule Kinoko.Lang.CheckTest do
  @moduledoc """
  The checker against the Rust crate's `tests/types_check.rs` (itself TS's
  `typecheck`/`review-fixes` tests). JSX, app-shape, map-key and hint-message
  cases are Task 8's.
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

  # ---------- names that do not resolve (hint messages are Task 8's) ----------

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

    assert {:error, _} = Parser.program(nested.(512))
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
end
