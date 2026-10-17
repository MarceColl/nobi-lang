defmodule Nobi.Lang.CheckTuplesTest do
  @moduledoc """
  Tuple patterns and the exhaustiveness of a `case` on a tuple, against the
  Rust crate's `tests/types_tuples.rs`. Its property test against the
  evaluator waits for the interpreter.
  """
  use ExUnit.Case, async: true

  import Nobi.Lang.CheckHelpers

  alias Nobi.Lang.Parser
  alias Nobi.Lang.Types.{Check, Stdlib}

  @int {:named, "Int"}

  defp tuple_case(t, arms) do
    "def A.f(p : #{t}) : Int do\n  case p do\n    #{Enum.join(arms, "\n    ")}\n  end\nend"
  end

  test "a tuple pattern binds each item at its type" do
    for ok <- [
          tuple_case("(Int, String)", ["(n, s) -> n + String.length(s)"]),
          tuple_case("(Option<(Int, Int)>, Bool)", [
            "(Option.Some((a, b)), true) -> a + b",
            "_ -> 0"
          ]),
          tuple_case("((Int, (Int, Bool)), Int)", ["((a, (b, false)), c) -> a + b + c", "_ -> 0"])
        ] do
      assert ty(checks(ok)) == @int, ok
    end

    typed =
      checks(
        "def A.f() : Int do case Option.None do Option.Some((a, b)) -> a + b\n _ -> 0 end end"
      )

    {:case, _, [scrutinee, _]} = typed
    assert ty(scrutinee) == {:applied, "Option", [{:tuple, [@int, @int]}]}

    err = first_error(tuple_case("(Int, String)", ["(n, s) -> n + s"]))

    assert {err.code, err.message} ==
             {"mismatch", "type mismatch: expected Int, got String in `s`"}
  end

  test "a tuple pattern of another shape is a type mismatch" do
    for {src, message} <- [
          {tuple_case("(Int, Int)", ["(a, b, c) -> a", "_ -> 0"]),
           "expected (Int, Int), got a tuple of 3 in `(a, b, c)`"},
          {tuple_case("((Int, Int), Int)", ["((a, b, c), d) -> d", "_ -> 0"]),
           "expected (Int, Int), got a tuple of 3 in `(a, b, c)`"},
          {tuple_case("(Option<Int>, Int)", ["(Option.Some((a, b)), _) -> a", "_ -> 0"]),
           "expected Int, got a tuple of 2 in `(a, b)`"},
          {"def A.f(n : Int) : Int do case n do (a, b) -> 1\n _ -> 0 end end",
           "expected Int, got a tuple of 2 in `(a, b)`"},
          {"deftype A.T do X | Y end\ndef A.f(t : A.T) : Int do case t do (a, b) -> 1\n _ -> 0 end end",
           "expected A.T, got a tuple of 2 in `(a, b)`"}
        ] do
      assert found(src) == [{"mismatch", "type mismatch: " <> message}], src
    end

    wide = "(" <> Enum.join(List.duplicate("_", 300), ", ") <> ") -> 1"
    err = first_error(tuple_case("(Int, Int)", [wide, "_ -> 0"]))
    assert err.code == "mismatch"

    assert String.starts_with?(
             err.message,
             "type mismatch: expected (Int, Int), got a tuple of 300 in `(_, _, "
           )

    assert String.ends_with?(err.message, "…`") and String.length(err.message) < 300
  end

  test "a tuple pattern binds each name once" do
    for src <- [
          tuple_case("(Int, (Int, Int))", ["(x, (y, x)) -> x", "_ -> 0"]),
          tuple_case("(Option<(Int, Int)>, Int)", ["(Option.Some((x, x)), _) -> x", "_ -> 0"])
        ] do
      assert found(src) == [{"bad-name", "`x` is already bound in this pattern"}], src
    end
  end

  test "a tuple case is exhaustive when its arms together match every value" do
    for {t, arms} <- [
          {"(Bool, Bool)",
           [
             "(true, true) -> 1",
             "(true, false) -> 2",
             "(false, true) -> 3",
             "(false, false) -> 4"
           ]},
          {"(Option<Int>, Result<Int, String>)",
           [
             "(Option.Some(n), Result.Ok(m)) -> n + m",
             "(Option.Some(_), Result.Err(_)) -> 1",
             "(Option.None, _) -> 0"
           ]},
          {"(Bool, (Bool, Option<Bool>))",
           [
             "(true, _) -> 1",
             "(false, (true, _)) -> 2",
             "(false, (false, Option.Some(true))) -> 3",
             "(false, (false, Option.Some(false))) -> 4",
             "(false, (_, Option.None)) -> 5"
           ]},
          {"(Option<(Bool, Int)>, Int)",
           [
             "(Option.Some((true, n)), _) -> n",
             "(Option.Some((false, _)), m) -> m",
             "(Option.None, _) -> 0"
           ]},
          {"(Int, String)", [~S|(0, "a") -> 1|, "q -> 2"]},
          {"(Int, String)", [~S|(0, "a") -> 1|, "(n, s) -> n"]},
          {"(Uuid, Int)", ["(_, 0) -> 0", "(u, n) -> n"]}
        ] do
      src = tuple_case(t, arms)
      assert ty(checks(src)) == @int, src
    end

    src =
      tuple_case("(Option<Int>, Result<Int, String>)", [
        "(Option.Some(_), Result.Ok(_)) -> 1",
        "(_, _) -> 0"
      ])

    assert sorted(last_checked(src).deps) == ["Option", "Result"]
  end

  test "a tuple case that misses a value names it" do
    for {t, arms, missing} <- [
          {"(Bool, Option<Int>)", ["(true, _) -> 1", "(false, Option.Some(_)) -> 2"],
           "(false, Option.None)"},
          {"(Bool, Bool)", ["(true, true) -> 1", "(true, false) -> 2", "(false, true) -> 3"],
           "(false, false)"},
          {"(Option<Int>, Result<Int, String>)",
           ["(Option.Some(n), Result.Ok(m)) -> n + m", "(Option.None, _) -> 0"],
           "(Option.Some(_), Result.Err(_))"},
          {"(Option<(Bool, Int)>, Int)",
           ["(Option.Some((true, _)), _) -> 1", "(Option.None, _) -> 0"],
           "(Option.Some((false, _)), _)"},
          {"(Bool, (Bool, Bool))",
           ["(true, _) -> 1", "(_, (true, _)) -> 2", "(false, (false, true)) -> 3"],
           "(false, (false, false))"},
          {"(Int, Bool)", ["(n, true) -> n"], "(_, false)"},
          {"(Int, Bool)", ["(0, _) -> 0", "(n, true) -> n"], "(1, false)"},
          {"(Int, Int)", ["(0, _) -> 0", "(1, _) -> 1", "(-1, 2) -> 2"], "(2, _)"},
          {"(String, Int)", [~S|("a", n) -> n|], ~S|("", _)|},
          {"(String, Int)", [~S|("", n) -> n|, ~S|("b", n) -> n|], ~S|("a", _)|},
          {"(Uuid, Bool)", ["(u, true) -> 1"], "(_, false)"},
          {"(Bool, Bool)", [], "_"}
        ] do
      src = tuple_case(t, arms)

      assert found(src) == [
               {"non-exhaustive", "case on `#{t}` is not exhaustive — missing: #{missing}"}
             ],
             src
    end
  end

  test "a tuple case refuses an arm no tuple matches" do
    on_tuple =
      {"bad-pattern",
       "pattern `Option.None` cannot match `p`, of type (Bool, Bool): only a deftype's values have variants — " <>
         "match it with a tuple pattern, `_` or a binder"}

    on_item =
      {"bad-pattern",
       "pattern `Option.None` cannot match item 1 of a tuple pattern, of type Bool: only a deftype's values have " <>
         "variants — match it with a literal, `_` or a binder"}

    literal = {"mismatch", "type mismatch: expected (Bool, Bool), got Bool in `true`"}

    for {arms, expected} <- [
          {["Option.None -> 1", "_ -> 0"], [on_tuple]},
          {["true -> 1", "_ -> 0"], [literal]},
          {["(Option.None, _) -> 1", "_ -> 0"], [on_item]},
          {["Option.None -> 1"], [on_tuple]}
        ] do
      src = tuple_case("(Bool, Bool)", arms)
      assert found(src) == expected, src
    end
  end

  test "a tuple case whose arm does not fit is one error" do
    assert found("def A.f() : Int do case (1, 2) do (a, b, c) -> a end end") == [
             {"mismatch", "type mismatch: expected (Int, Int), got a tuple of 3 in `(a, b, c)`"}
           ]
  end

  test "a tuple case is weighed once its items' types are known" do
    body = fn arms, then ->
      msg() <>
        "def M.f(s : String, n : Int) : Int do\n  x = JSON.parse(s)\n  " <>
        "y = case (x, n) do\n    #{Enum.join(arms, "\n    ")}\n  end\n  #{then}\nend"
    end

    settled = "case x do\n    Result.Ok(m) -> M.handle(m) + y\n    Result.Err(_) -> y\n  end"

    all = [
      "(Result.Ok(M.Msg.Inc), _) -> 1",
      "(Result.Ok(M.Msg.Dec), _) -> 2",
      "(Result.Ok(M.Msg.Set(_)), _) -> 3"
    ]

    arms = all ++ ["(Result.Err(_), _) -> 0"]
    assert ty(checks(body.(arms, settled))) == @int

    expected =
      "case on `(Result<M.Msg, String>, Int)` is not exhaustive — missing: (Result.Ok(M.Msg.Dec), _)"

    without_dec = [Enum.at(arms, 0), Enum.at(arms, 2), Enum.at(arms, 3)]
    assert found(body.(without_dec, settled)) == [{"non-exhaustive", expected}]

    assert found(body.(arms, "y")) == [
             {"cannot-infer", "cannot infer the type of `JSON.parse(s)`"}
           ]
  end

  test "a tuple case whose item holds a type never known is refused" do
    types = "deftype P.Box<T> do Full(T) | Empty end\ndeftype P.W do W(P.Box) end\n"

    found_in = fn def_ ->
      case last_checked(types <> def_).result do
        {:ok, _} -> []
        {:error, errs} -> Enum.map(errs, &{&1.code, &1.message})
      end
    end

    arm = "P.W.W(P.Box.Full(Option.Some(_)))"
    tuple = "def P.f(p : (P.W, Bool)) : Int do case p do (#{arm}, _) -> 1 end end"

    assert found_in.(tuple) == [
             {"non-exhaustive", "case on `(P.W, Bool)` is not exhaustive — missing: _"}
           ]

    variant = "def P.f(w : P.W) : Int do case w do #{arm} -> 1 end end"

    assert found_in.(variant) == [
             {"non-exhaustive", "case on `P.W` is not exhaustive — missing: P.W.W"}
           ]
  end

  test "a tuple arm no value reaches is accepted as any such arm is" do
    for src <- [
          "deftype A.T do X | Y end\ndef A.f(t : A.T) : Int do case t do A.T.X -> 1\n A.T.X -> 2\n _ -> 3 end end",
          "def A.f(n : Int) : Int do case n do _ -> 1\n 2 -> 2 end end",
          tuple_case("(Bool, Bool)", [
            "(true, _) -> 1",
            "(true, true) -> 2",
            "(false, _) -> 3",
            "_ -> 4"
          ])
        ] do
      assert ty(checks(src)) == @int, src
    end
  end

  test "an irrefutable tuple pattern inside a variant covers it" do
    for {t, arms} <- [
          {"Option<(Int, Int)>", "Option.Some((a, b)) -> a + b\n Option.None -> 0"},
          {"Option<((Int, Int), Bool)>", "Option.Some(((a, _), b)) -> a\n Option.None -> 0"},
          {"Result<(Int, Int), (String, Int)>",
           "Result.Ok((a, b)) -> a\n Result.Err((_, n)) -> n"}
        ] do
      src = "def A.f(o : #{t}) : Int do case o do #{arms} end end"
      assert ty(checks(src)) == @int, src
    end
  end

  test "a refutable tuple pattern inside a variant leaves it uncovered" do
    case_ = &"def A.f(o : Option<(Bool, Int)>) : Int do case o do #{&1} end end"
    missing = {"non-exhaustive", "case on `Option` is not exhaustive — missing: Option.Some"}

    for arms <- [
          "Option.Some((true, x)) -> x\n Option.None -> 0",
          "Option.Some((true, x)) -> x\n Option.Some((false, y)) -> y\n Option.None -> 0",
          "Option.Some((x, (1))) -> 1\n Option.None -> 0"
        ] do
      err = first_error(case_.(arms))
      assert {err.code, err.message} == missing, arms
    end

    covered = case_.("Option.Some((true, x)) -> x\n Option.Some(_) -> 1\n Option.None -> 0")
    assert ty(checks(covered)) == @int

    err =
      first_error(
        "def A.f(o : Option<(Option<Int>, Int)>) : Int do case o do Option.Some((Option.Some(a), b)) -> b\n " <>
          "Option.Some((Option.None, b)) -> b\n Option.None -> 0 end end"
      )

    assert {err.code, err.message} == missing

    assert found(case_.("Option.Some((a, b, c)) -> 1\n Option.None -> 0")) == [
             {"mismatch", "type mismatch: expected (Bool, Int), got a tuple of 3 in `(a, b, c)`"},
             missing
           ]
  end

  defp bools(bits) do
    items =
      for i <- 0..11,
          do: if(Bitwise.band(Bitwise.bsr(bits, 11 - i), 1) == 1, do: "true", else: "false")

    "(" <> Enum.join(items, ", ") <> ")"
  end

  @tag timeout: 120_000
  @tag :perf
  test "a wide tuple of bools is checked exactly in bounded time" do
    t = "(" <> Enum.join(List.duplicate("Bool", 12), ", ") <> ")"
    arms = for bits <- 0..4095, do: "#{bools(bits)} -> #{bits}"

    {us, _} =
      :timer.tc(fn ->
        assert ty(checks(tuple_case(t, arms))) == @int
        without = Enum.take(arms, 1234) ++ Enum.drop(arms, 1235)
        err = first_error(tuple_case(t, without))

        assert {err.code, err.message} ==
                 {"non-exhaustive", "case on `#{t}` is not exhaustive — missing: #{bools(1234)}"}
      end)

    assert us < 10_000_000
  end

  defp splitting(width) do
    arm = fn set, body ->
      items =
        for i <- 0..(width - 1) do
          case List.keyfind(set, i, 0) do
            {_, b} -> to_string(b)
            nil -> "_"
          end
        end

      "(" <> Enum.join(items, ", ") <> ") -> #{body}"
    end

    arms =
      Enum.flat_map(0..(width - 2), fn i ->
        [arm.([{i, true}, {width - 1, true}], 1), arm.([{i, false}, {width - 1, true}], 2)]
      end) ++ [arm.([{width - 1, false}], 3)]

    {"(" <> Enum.join(List.duplicate("Bool", width), ", ") <> ")", arms}
  end

  @tag timeout: 120_000
  @tag :perf
  test "a tuple case too complex to check is refused in bounded time" do
    {t, arms} = splitting(40)

    {us, _} =
      :timer.tc(fn ->
        err = first_error(tuple_case(t, arms))
        assert err.code == "non-exhaustive"
        assert err.message =~ "is too complex to check that it is exhaustive"
        assert String.ends_with?(err.message, "— end it with a `_` or binder arm")
        assert ty(checks(tuple_case(t, arms ++ ["_ -> 0"]))) == @int
      end)

    assert us < 10_000_000
  end

  @tag timeout: 120_000
  test "the tuple cases of a declaration share one budget" do
    {t, arms} = splitting(11)

    def_ = fn name, cases ->
      case_ = "case p do\n    #{Enum.join(arms, "\n    ")}\n  end"
      lets = for i <- 0..(cases - 1), into: "", do: "  x#{i} = #{case_}\n"
      "def A.#{name}(p : #{t}) : Int do\n#{lets}  0\nend\n"
    end

    apart = def_.("f", 1) <> def_.("g", 1)
    assert Enum.all?(check_all(apart), fn {_, c} -> match?({:ok, _}, c.result) end)

    for cases <- [2, 200] do
      found = found(def_.("f", cases))
      assert length(found) == cases - 1

      for {code, message} <- found do
        assert code == "non-exhaustive"
        assert message =~ "is too complex to check that it is exhaustive"
      end
    end
  end

  test "a wide tuple case names what it misses" do
    t = "(" <> Enum.join(List.duplicate("Int", 600), ", ") <> ")"
    arm = "(" <> Enum.join(List.duplicate("_", 599), ", ") <> ", 0) -> 1"
    err = first_error(tuple_case(t, [arm]))
    assert err.code == "non-exhaustive"
    assert err.message =~ "` is not exhaustive — missing: (_, _, _, "
  end

  test "check_expr weighs a tuple case" do
    {:ok, expr} = Parser.expr("case (1, true) do\n  (n, true) -> n\nend")
    {:error, errs} = Check.expr(expr, Stdlib.signatures()).result

    assert Enum.map(errs, &{&1.code, &1.message}) == [
             {"non-exhaustive", "case on `(Int, Bool)` is not exhaustive — missing: (_, false)"}
           ]
  end
end
