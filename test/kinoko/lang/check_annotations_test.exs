defmodule Kinoko.Lang.CheckAnnotationsTest do
  @moduledoc """
  Type annotations `(e : T)` and the lone expression (`Check.expr`), against
  the Rust crate's `tests/types_annotations.rs`.
  """
  use ExUnit.Case, async: true

  import Kinoko.Lang.CheckHelpers

  alias Kinoko.Lang.Types.Extract

  @int {:named, "Int"}

  test "an annotation fixes an otherwise open type" do
    err = first_error("def A.f() : Int do List.length([]) end")
    assert {err.code, err.message} == {"cannot-infer", "cannot infer the type of `[]`"}

    typed = checks("def A.f() : Int do List.length(([] : List<Int>)) end")
    {:call, _, [_, [{:annot, _, [list, t]} = annot]]} = typed
    list_of_int = {:applied, "List", [@int]}
    assert {ty(annot), ty(list), t} == {list_of_int, list_of_int, list_of_int}
  end

  test "an annotation that does not fit is a mismatch" do
    found_in = &found("def A.f() : Int do #{&1} end")

    assert found_in.(~S|("a" : Int) + 1|) == [
             {"mismatch", ~S|type mismatch: expected Int, got String in `"a"`|}
           ]

    assert found_in.("List.length(([1] : List<String>))") == [
             {"mismatch", "type mismatch: expected List<String>, got List<Int> in `[1]`"}
           ]
  end

  test "an annotation's type is validated as any annotation" do
    first = fn body ->
      e = first_error("def A.f() : Int do\n  x = #{body}\n  1\nend")
      {e.code, e.message}
    end

    variable = fn name ->
      {"unbound",
       "unknown type `#{name}` — an annotation names concrete types; `#{name}` in an answer means any type and " <>
         "cannot be written"}
    end

    assert first.("([] : List<a>)") == variable.("a")
    assert first.("([] : List<t<Int>>)") == variable.("t")
    assert first.("([] : List<A.Nope>)") == {"unbound", "unknown type `A.Nope`"}

    assert first.("([] : List<Int, Int>)") ==
             {"arity", "type `List` expects 1 parameter(s), got 2"}

    assert first.("(%{} : Map<(Int -> Int), Int>)") ==
             {"non-data-map-key",
              "the type `Map<(Int -> Int), Int>` holds a `Map` whose key is not data — map keys cannot hold a " <>
                "function, `Cmd`, or `Html`"}
  end

  test "an annotation's types are dependencies" do
    src = "deftype M.T do A end\ndef M.f() : Int do List.length(([] : List<M.T>)) end"
    checked = last_checked(src)
    assert {:ok, _} = checked.result
    want = MapSet.new(["List.length", "M.T"])
    assert checked.deps == want
    assert Extract.deps(Enum.at(parse(src), 1)) == want

    checked = last_checked("def M.f() : Int do List.length(([] : List<M.T>)) end")
    assert {:error, _} = checked.result
    assert checked.deps == want
  end

  test "an annotation keeps what its expression resolves to" do
    msg = "deftype E.Msg do Set(String) end\n"

    typed =
      all_ok(
        msg <>
          "def E.v() : Html<E.Msg> do <input on-change={(E.Msg.Set : (String -> E.Msg))} /> end"
      )

    {:def, _, [_, _, _, {:block, _, [_, {:jsx, _, [_, [{:event, _, handler}], _]}]}]} =
      typed["E.v"]

    assert res(handler) == {:ctor_ref, "E.Msg", "Set", 1}
  end

  test "check_expr leaves a type open" do
    types = fn src ->
      {:ok, types} = lone_types(src)
      types
    end

    assert types.("[]") == ["List<a>"]

    assert types.("(%{}, [], Option.None)") ==
             ["(Map<a, b>, List<c>, Option<d>)", "Map<a, b>", "List<c>", "Option<d>"]

    assert types.("(List.length([]), [])") == ["(Int, List<a>)", "Int", "List<b>", "List<a>"]
    assert types.("List.concat([], [])") == ["List<a>", "List<a>", "List<a>"]
    assert types.("List.append([], [])") == ["List<List<a>>", "List<List<a>>", "List<a>"]
    assert types.("([] : List<Int>)") == ["List<Int>", "List<Int>"]
    many = types.("(" <> Enum.join(List.duplicate("[]", 28), ", ") <> ")")
    assert Enum.drop(many, 26) == ["List<z>", "List<a1>", "List<b1>"]
  end

  test "check_expr weighs a tuple case of an open type" do
    case_ = &lone_types("case (Option.None, 1) do\n#{&1}\nend")

    found_in = fn arms ->
      {:error, errs} = case_.(arms)
      Enum.map(errs, &{&1.code, &1.message})
    end

    missing = &[{"non-exhaustive", "case on `#{&1}` is not exhaustive — missing: #{&2}"}]

    assert found_in.("  (Option.Some(_), _) -> 1") ==
             missing.("(Option<_>, Int)", "(Option.None, _)")

    assert {:ok, ["Int" | _]} = case_.("  (Option.Some(Result.Ok(_)), _) -> 1\n  (_, n) -> n")
    ok_arm = "  (Option.Some(Result.Ok(_)), _) -> 1"

    assert found_in.(ok_arm <> "\n  (Option.None, n) -> n") ==
             missing.("(Option<Result<_, _>>, Int)", "(Option.Some(Result.Err(_)), _)")

    assert {:ok, ["Int" | _]} =
             case_.(ok_arm <> "\n  (Option.Some(Result.Err(_)), _) -> 2\n  (Option.None, n) -> n")
  end

  test "check_expr checks a pattern of an open type by its name" do
    program = "deftype P.T do A | B end\ndefmodel P.M do x : Int end"
    case_ = &lone_types_in(program, "case Option.None do\n#{&1}\n  _ -> 2\nend")

    refused = fn arms ->
      {:error, errs} = case_.(arms)
      Enum.map(errs, &{&1.code, &1.message})
    end

    bad = &[{"bad-pattern", &1}]
    unknown = &[{"unbound", &1}]
    int = {:ok, ["Int"]}

    assert case_.("  Option.Some(Option.Some(_)) -> 1") == int
    assert case_.("  Option.Some(P.T.A) -> 1") == int

    assert case_.("  Option.Some(Option.Some(P.T.B)) -> 1\n  Option.Some(Option.None) -> 3") ==
             int

    assert refused.("  Option.Some(Nope.X) -> 1") ==
             unknown.("unknown type `Nope` in pattern `Nope.X`")

    assert refused.("  Option.Some(Foo) -> 1") == unknown.("unknown type `Foo` in pattern `Foo`")

    assert refused.("  Option.Some(Option.Some(Nope.X)) -> 1") ==
             unknown.("unknown type `Nope` in pattern `Nope.X`")

    {:error, undeclared} =
      lone_types("case Option.None do\n  Option.Some(P.T.A) -> 1\n  _ -> 2\nend")

    assert Enum.map(undeclared, &{&1.code, &1.message}) ==
             unknown.("unknown type `P.T` in pattern `P.T.A`")

    assert refused.("  Option.Some(P.M.A) -> 1") == bad.("`P.M` has no variant `A`")
    assert refused.("  Option.Some(P.T.C) -> 1") == bad.("`P.T` has no variant `C`")

    assert refused.("  Option.Some(P.T.A(1)) -> 1") ==
             bad.("pattern `P.T.A` expects 0 argument(s), got 1")

    assert refused.("  Option.Some(P.T.A) -> 1\n  Option.Some(Option.None) -> 3") ==
             bad.("pattern `Option.None` does not belong to `P.T`")
  end
end
