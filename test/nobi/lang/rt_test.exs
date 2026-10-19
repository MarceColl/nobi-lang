defmodule Nobi.Lang.RtTest do
  # Ported from kinoko-next `interp/value.rs` (unit tests) and
  # `tests/interp_stdlib.rs`, at the Rt level: stdlib bodies called directly
  # with BEAM values. Tests that need the evaluator are listed in the task-2
  # report under "Deferred to Task 4".
  use ExUnit.Case, async: true

  alias Nobi.Lang.Rt
  alias Nobi.Lang.Rt.Stdlib
  alias Nobi.Lang.Types.Stdlib, as: Sigs

  @id "0b9e2c4a-1f3d-4e5f-8a7b-6c5d4e3f2a1b"
  @max 9_223_372_036_854_775_807
  @min -9_223_372_036_854_775_808

  defp some(v), do: {:var, "Option", "Some", [v]}
  defp none, do: {:var, "Option", "None", []}
  defp uuid(s), do: {:uuid, s}
  defp rec(model, fields), do: {:rec, model, Map.new(fields, fn {k, v} -> {to_string(k), v} end)}
  defp error(f), do: catch_throw(f.())

  # ---------- arithmetic ----------

  describe "checked arithmetic" do
    test "i64 overflow is a runtime error" do
      assert catch_throw(Rt.add(@max, 1)) == {:nobi_error, "integer overflow"}
      assert {:nobi_error, "integer overflow"} = catch_throw(Rt.mul(@min, -1))
      assert {:nobi_error, "integer overflow"} = catch_throw(Rt.sub(@min, 1))
      assert {:nobi_error, "integer overflow"} = catch_throw(Rt.div(@min, -1))
      assert {:nobi_error, "integer overflow"} = catch_throw(Rt.neg(@min))
    end

    test "in range it is plain arithmetic, division truncating toward zero" do
      assert Rt.add(@min, @max) == -1
      assert Rt.sub(5, 7) == -2
      assert Rt.mul(-3, 4) == -12
      assert Rt.div(7, 2) == 3
      assert Rt.div(-7, 2) == -3
      assert Rt.neg(@max) == -@max
    end

    test "division by zero" do
      assert catch_throw(Rt.div(1, 0)) == {:nobi_error, "division by zero"}
    end

    test "Float arithmetic is plain, with no NaN, infinity or -0.0" do
      assert Rt.add(1.5, 2.25) == 3.75
      assert Rt.sub(1.0, 0.25) == 0.75
      assert Rt.mul(1.5, 2.0) == 3.0
      assert Rt.div(1.0, 4.0) == 0.25
      assert Rt.neg(1.5) == -1.5
      assert catch_throw(Rt.mul(1.0e308, 10.0)) == {:nobi_error, "float overflow"}
      assert catch_throw(Rt.add(1.7e308, 1.7e308)) == {:nobi_error, "float overflow"}
      assert catch_throw(Rt.div(1.0, 0.0)) == {:nobi_error, "division by zero"}
      assert catch_throw(Rt.div(1.0, -0.0)) == {:nobi_error, "division by zero"}

      for zero <- [
            Rt.neg(0.0),
            Rt.mul(-1.0, 0.0),
            Rt.sub(-0.0, 0.0),
            Rt.constant({:neg, [], [{:float, [], [0.0]}]})
          ] do
        assert zero === 0.0
        assert Rt.eq(zero, 0.0)
      end
    end

    test "a Float's canonical text" do
      for {f, text} <- [
            {1.0, "1.0"},
            {1000.0, "1000.0"},
            {0.1, "0.1"},
            {-2.5e-3, "-0.0025"},
            {1.0e-6, "0.000001"},
            {1.0e-7, "1.0e-7"},
            {1.0e20, "100000000000000000000.0"},
            {1.0e21, "1.0e21"},
            {1234.567, "1234.567"}
          ] do
        assert Rt.float_text(f) == text
        assert String.to_float(text) == f
      end
    end

    test "concat joins strings" do
      assert Rt.concat("a", "bé") == "abé"
    end
  end

  # ---------- equality and order (value.rs) ----------

  describe "equality" do
    test "data is equal by structure" do
      a = fn ->
        {[1, "x", true], rec("M.Model", count: 1, name: "n"), Rt.variant("M.Msg", "Add", [2]),
         Rt.cmd_batch([Rt.cmd_none(), Rt.cmd_effect("Cmd.time.now", nil, [1])])}
      end

      assert Rt.eq(a.(), a.())
      refute Rt.eq([1, 2], [2, 1])
      refute Rt.eq(rec("M.Model", count: 1), rec("M.Other", count: 1))
      refute Rt.eq(Rt.variant("M.Msg", "Add", [1]), Rt.variant("M.Msg", "Sub", [1]))
      refute Rt.eq(1, "1")
      refute Rt.eq(Rt.cmd_none(), Rt.cmd_batch([]))
    end

    test "map equality ignores insertion order" do
      assert Rt.eq(Map.new([{1, "x"}, {2, "y"}]), Map.new([{2, "y"}, {1, "x"}]))
      refute Rt.eq(%{1 => "x"}, %{1 => "y"})
    end
  end

  describe "compare" do
    test "data is totally ordered" do
      lt = fn a, b -> Rt.compare(a, b) == :lt and Rt.compare(b, a) == :gt end
      assert lt.(-1, 2) and lt.(2, 10)
      assert lt.("B", "a") and lt.("a", "ab") and lt.("z", "é")
      assert lt.(false, true)
      assert lt.([1, 2], [1, 3]) and lt.([1], [1, 0])
      assert lt.({1, "b"}, {2, "a"})
      assert lt.(none(), some(0))
      assert lt.(some(1), some(2))
      assert lt.(%{1 => 9}, %{2 => 0})
      # Values of different kinds (never keys of one map) order by kind.
      assert lt.(5, "") and lt.("", false)

      assert Enum.sort(["b", 3, "a", -3], &(Rt.compare(&1, &2) != :gt)) == [-3, 3, "a", "b"]

      for {a, b} <- [{1, 1}, {"x", "x"}, {[1], [1]}] do
        assert Rt.compare(a, b) == :eq
      end
    end

    test "kinds order Int, Str, Bool, Uuid, List, Map, Tuple, Record, Variant, Fn, Cmd, Float" do
      kinds = [
        1,
        "s",
        true,
        uuid(@id),
        [1],
        %{1 => 1},
        {1, 2},
        rec("M.R", n: 1),
        some(1),
        fn -> 1 end,
        Rt.cmd_none(),
        1.5
      ]

      for {a, i} <- Enum.with_index(kinds), {b, j} <- Enum.with_index(kinds) do
        expected =
          cond do
            i < j -> :lt
            i > j -> :gt
            true -> :eq
          end

        assert Rt.compare(a, b) == expected, "#{inspect(a)} vs #{inspect(b)}"
      end
    end

    test "records, variants, maps and cmds order by their parts" do
      assert Rt.compare(rec("A.M", n: 9), rec("B.M", n: 0)) == :lt
      assert Rt.compare(rec("A.M", a: 2), rec("A.M", a: 1, b: 0)) == :gt
      assert Rt.compare(rec("A.M", a: 1), rec("A.M", a: 1, b: 0)) == :lt
      assert Rt.compare(Rt.variant("A.T", "B", []), Rt.variant("A.T", "A", [9])) == :gt
      assert Rt.compare(%{1 => 2, 3 => 4}, %{1 => 2}) == :gt
      assert Rt.compare(%{-5 => 0}, %{1 => 0}) == :lt
      assert Rt.compare(Rt.cmd_none(), Rt.cmd_batch([])) == :lt

      assert Rt.compare(Rt.cmd_batch([]), Rt.cmd_effect("Cmd.time.now", nil, [])) == :lt

      assert Rt.compare(
               Rt.cmd_effect("Cmd.store.list", nil, []),
               Rt.cmd_effect("Cmd.store.list", "A.M", [])
             ) == :lt

      assert Rt.compare({}, {1, 2}) == :lt
    end

    test "sorted_entries iterates a map in key order" do
      m = Map.new([{3, 0}, {-1, 0}, {2, 0}])
      assert Rt.sorted_entries(m) == [{-1, 0}, {2, 0}, {3, 0}]
      big = Map.new(1..40, &{&1, &1})
      assert Enum.map(Rt.sorted_entries(big), &elem(&1, 0)) == Enum.to_list(1..40)
    end
  end

  # ---------- constructors ----------

  describe "constructors" do
    test "record, variant and field access" do
      r = Rt.record("M.Model", %{"count" => 1})
      assert r == {:rec, "M.Model", %{"count" => 1}}
      assert Rt.variant("M.Msg", "Add", [1]) == {:var, "M.Msg", "Add", [1]}
      assert Rt.field(r, "count") == 1

      assert error(fn -> Rt.field(r, "nope") end) ==
               {:nobi_error, "a `M.Model` has no field `nope`"}

      assert Rt.update(r, %{"count" => 2}) == {:rec, "M.Model", %{"count" => 2}}
    end

    test "a constructor reference is a fun building the variant" do
      f = Rt.ctor("M.Msg", "Pair", 2)
      assert is_function(f, 2)
      assert f.(1, "a") == {:var, "M.Msg", "Pair", [1, "a"]}
      assert Rt.ctor("M.Msg", "Got", 1).(3) == {:var, "M.Msg", "Got", [3]}
    end

    test "html element is the Html variant with attributes as pairs" do
      element = Rt.html_element("p", [{"class", "big"}], [Rt.html_text("hi")])
      text = {:var, "Html", "Text", ["hi"]}
      assert element == {:var, "Html", "Element", ["p", [{"class", "big"}], [text]]}
      assert Rt.html_text("hi") == text
    end

    test "children are spliced: lists flattened, scalars written as text" do
      b = Rt.html_element("b", [], [])

      assert Rt.html_element("div", [], ["a", 1, true, uuid(@id), [b, ["x"]], b]) ==
               {:var, "Html", "Element",
                [
                  "div",
                  [],
                  [
                    Rt.html_text("a"),
                    Rt.html_text("1"),
                    Rt.html_text("true"),
                    Rt.html_text(@id),
                    b,
                    Rt.html_text("x"),
                    b
                  ]
                ]}

      assert error(fn -> Rt.html_element("div", [], [rec("M.R", [])]) end) ==
               {:nobi_error, "expected Html, text or a list of them, got a record"}
    end

    test "none and batch hold what they are given; a batch keeps bare inner cmds" do
      now = Rt.cmd_effect("Cmd.time.now", nil, [Rt.ctor("C.Msg", "Got", 1)])
      inner = Rt.cmd_batch([now])
      assert Rt.cmd_none() == {:cmd, :none}
      {:cmd, {:effect, "Cmd.time.now", nil, [_]}} = now
      {:cmd, inner_bare} = inner
      assert Rt.cmd_batch([Rt.cmd_none(), inner]) == {:cmd, {:batch, [:none, inner_bare]}}
    end
  end

  # ---------- the stdlib table ----------

  describe "function_for" do
    test "every stdlib def has a function of its arity, named by its snake-cased name" do
      checked =
        for {name, {:def, params, _, _}} <- Sigs.signatures() do
          assert {Stdlib, fun, arity} = Stdlib.function_for(name), name
          assert arity == length(params), name
          assert Atom.to_string(fun) == name |> String.replace(".", "_") |> String.downcase()
          assert function_exported?(Stdlib, fun, arity), name
        end

      assert length(checked) > 60

      assert Stdlib.function_for("List.map") == {Stdlib, :list_map, 2}
      assert Stdlib.function_for("Option.with_default") == {Stdlib, :option_with_default, 2}
      assert Stdlib.function_for("Option") == nil
      assert Stdlib.function_for("No.such") == nil
    end
  end

  # ---------- List (interp_stdlib.rs) ----------

  describe "List" do
    test "map, filter, append, concat, length, is_empty, foldl, reverse, head" do
      assert Stdlib.list_map([1, 2], &(&1 * 2)) == [2, 4]
      assert Stdlib.list_filter([1, 2, 3], &(&1 > 1)) == [2, 3]
      assert Stdlib.list_append([1], 2) == [1, 2]
      assert Stdlib.list_concat([1], [2, 3]) == [1, 2, 3]
      assert Stdlib.list_length([1, 2]) == 2
      assert Stdlib.list_is_empty([]) and not Stdlib.list_is_empty([1])
      assert Stdlib.list_foldl(["a", "b"], "", &Stdlib.string_concat/2) == "ba"
      assert Stdlib.list_reverse([1, 2, 3]) == [3, 2, 1]
      assert Stdlib.list_head([]) == none()
      assert Stdlib.list_head([7, 8]) == some(7)
    end

    test "sum overflow is an error" do
      assert error(fn -> Stdlib.list_sum([@max, 1]) end) == {:nobi_error, "integer overflow"}
      assert error(fn -> Stdlib.list_sum([@max, 1, -1]) end) == {:nobi_error, "integer overflow"}
      assert Stdlib.list_sum([@min, @max]) == -1
    end

    test "maximum and minimum" do
      assert Stdlib.list_maximum([3, 9, -1]) == some(9)
      assert Stdlib.list_minimum([3, 9, -1]) == some(-1)
      assert Stdlib.list_maximum([]) == none()
    end

    test "sort_by keeps equal keys in their order" do
      sorted = Stdlib.list_sort_by(["bb", "a", "cc", "d", "e"], &Stdlib.string_length/1)
      assert sorted == ["a", "d", "e", "bb", "cc"]
    end

    test "take and drop clamp at any count" do
      xs = [1, 2, 3]

      for {n, take, drop} <- [
            {@min, [], xs},
            {-1, [], xs},
            {0, [], xs},
            {1, [1], [2, 3]},
            {3, xs, []},
            {@max, xs, []}
          ] do
        assert Stdlib.list_take(xs, n) == take, "take #{n}"
        assert Stdlib.list_drop(xs, n) == drop, "drop #{n}"
      end
    end

    test "all and any stop at the element that decides" do
      refute Stdlib.list_all([1, 0], fn x -> Rt.div(1, x) > 5 end)
      assert Stdlib.list_any([1, 0], fn x -> Rt.div(1, x) == 1 end)

      assert error(fn -> Stdlib.list_all([0, 1], fn x -> Rt.div(1, x) > 5 end) end) ==
               {:nobi_error, "division by zero"}

      assert Stdlib.list_all([], fn _ -> false end)
      refute Stdlib.list_any([], fn _ -> true end)
    end

    test "member is by equality" do
      assert Stdlib.list_member([%{1 => 2}], %{1 => 2})
      refute Stdlib.list_member([[1]], [2])
    end

    test "filter_map keeps the Somes" do
      assert Stdlib.list_filter_map([[1], [], [2, 3]], &Stdlib.list_head/1) == [1, 2]
    end

    test "a stdlib function passed as a value is the same function" do
      assert Stdlib.list_map(["a", "bb", "👋"], &Stdlib.string_length/1) == [1, 2, 1]
    end
  end

  # ---------- String ----------

  describe "String" do
    test "to_int reads every i64, strictly" do
      assert Stdlib.string_to_int("9007199254740993") == some(9_007_199_254_740_993)
      assert Stdlib.string_to_int("9223372036854775807") == some(@max)
      assert Stdlib.string_to_int("-9223372036854775808") == some(@min)
      assert Stdlib.string_to_int("9223372036854775808") == none()
      assert Stdlib.string_to_int("-0") == some(0)
      assert Stdlib.string_to_int("007") == some(7)

      for bad <- ["+1", "-", "1-", "1\n", "١", "0x10", "1_000", ""] do
        assert Stdlib.string_to_int(bad) == none(), inspect(bad)
      end
    end

    test "to_int refuses a huge digit string quickly, and reads past leading zeros" do
      huge = String.duplicate("7", 2_000_000)
      {micros, result} = :timer.tc(fn -> Stdlib.string_to_int(huge) end)
      assert result == none()
      assert Stdlib.string_to_int("-" <> huge) == none()
      # Bignum parsing of 2M digits takes seconds; the refusal is a scan.
      assert micros < 1_000_000

      zeros = String.duplicate("0", 2_000_000)
      assert Stdlib.string_to_int(zeros <> "42") == some(42)
      assert Stdlib.string_to_int("-" <> zeros <> "9223372036854775808") == some(@min)
      assert Stdlib.string_to_int(zeros) == some(0)
    end

    test "length counts code points, not graphemes" do
      assert Stdlib.string_length("") == 0
      assert Stdlib.string_length("e\u0301") == 2
      assert Stdlib.string_length("👩‍👩‍👧") == 5
      assert Stdlib.string_length(String.duplicate("ü", 1000)) == 1000
    end

    test "trim trims what Rust calls whitespace" do
      assert Stdlib.string_trim("\u0085 a \u0085") == "a"
      assert Stdlib.string_trim("\uFEFFa\uFEFF") == "\uFEFFa\uFEFF"
      assert Stdlib.string_trim("\t\n\r \u00A0\u2028a\u3000") == "a"
    end

    test "slice counts a negative end back from the end" do
      assert Stdlib.string_slice("abcd", 1, -1) == "bc"
      assert Stdlib.string_slice("a👋b", -5, -1) == "a👋"
      assert Stdlib.string_slice("abc", 1, -9) == ""
      assert Stdlib.string_slice("abc", 5, 9) == ""
      assert Stdlib.string_slice("abc", @min, @max) == "abc"
      assert Stdlib.string_slice("abc", @max, @min) == ""
    end

    test "strings are code points everywhere" do
      assert Stdlib.string_length("é👋") == 2
      # e + combining acute: two code points, one grapheme
      assert Stdlib.string_length("é") == 2
      assert Stdlib.string_split("é👋", "") == ["é", "👋"]
      assert Stdlib.string_split("", "") == []
      assert Stdlib.string_split("", ",") == [""]
      assert Stdlib.string_split(",a,", ",") == ["", "a", ""]
      assert Stdlib.string_reverse("é👋a") == "a👋é"
      assert Stdlib.string_reverse("éx") == "x́e"
      assert Stdlib.string_to_upper("straße") == "STRASSE"
    end

    test "to_lower writes a word-final sigma as Rust does" do
      assert Stdlib.string_to_lower("ΟΔΟΣ") == "οδος"
      assert Stdlib.string_to_lower("Σ") == "σ"
      assert Stdlib.string_to_lower("ΣΑ") == "σα"
      assert Stdlib.string_to_lower("ΑΣ ΑΣ.") == "ας ας."
    end

    test "the rest" do
      assert Stdlib.string_concat("a", "b") == "ab"
      assert Stdlib.string_from_int(-12) == "-12"
      assert Stdlib.string_is_empty("") and not Stdlib.string_is_empty(" ")
      assert Stdlib.string_contains("abc", "bc") and Stdlib.string_contains("abc", "")
      refute Stdlib.string_contains("abc", "cb")
      assert Stdlib.string_starts_with("abc", "ab") and not Stdlib.string_starts_with("abc", "b")
      assert Stdlib.string_join(["a", "b", "c"], ", ") == "a, b, c"
      assert Stdlib.string_join([], ", ") == ""
    end
  end

  # ---------- Option ----------

  describe "Option" do
    test "with_default, map, and_then" do
      assert Stdlib.option_with_default(some(1), 0) == 1
      assert Stdlib.option_with_default(none(), 0) == 0
      assert Stdlib.option_map(some(1), &(&1 + 1)) == some(2)
      assert Stdlib.option_map(none(), &(&1 + 1)) == none()
      assert Stdlib.option_and_then(some(1), fn x -> some(x * 10) end) == some(10)
      assert Stdlib.option_and_then(some(1), fn _ -> none() end) == none()
      assert Stdlib.option_and_then(none(), fn x -> some(x) end) == none()
    end
  end

  # ---------- Cmd and Tx ----------

  describe "Cmd and Tx" do
    test "every effect is its name and its arguments" do
      row = rec("C.Row", text: "t")
      saved = Rt.ctor("C.Msg", "Saved", 1)
      got = Rt.ctor("C.Msg", "Got", 1)
      text = Rt.ctor("C.Msg", "Text", 1)
      eff = fn name, args -> {:cmd, {:effect, name, nil, args}} end

      cases = [
        {Stdlib.cmd_store_insert(row, saved), eff.("Cmd.store.insert", [row, saved])},
        {Stdlib.cmd_store_update(uuid(@id), row, saved),
         eff.("Cmd.store.update", [uuid(@id), row, saved])},
        {Stdlib.cmd_store_tx(&Function.identity/1, saved),
         eff.("Cmd.store.tx", [&Function.identity/1, saved])},
        {Stdlib.cmd_time_now(got), eff.("Cmd.time.now", [got])},
        {Stdlib.cmd_random_int(1, 6, got), eff.("Cmd.random.int", [1, 6, got])},
        {Stdlib.cmd_blob_put("k", "v", text), eff.("Cmd.blob.put", ["k", "v", text])},
        {Stdlib.cmd_blob_get("k", text), eff.("Cmd.blob.get", ["k", text])},
        {Stdlib.cmd_blob_list("p", text), eff.("Cmd.blob.list", ["p", text])},
        {Stdlib.cmd_blob_delete("k", text), eff.("Cmd.blob.delete", ["k", text])},
        {Stdlib.cmd_ai_generate("m", "p", text), eff.("Cmd.ai.generate", ["m", "p", text])},
        {Stdlib.cmd_time_after(10, got), eff.("Cmd.time.after", [10, got])}
      ]

      for {got_cmd, want} <- cases, do: assert(got_cmd == want)

      assert Stdlib.cmd_none() == {:cmd, :none}
      assert Stdlib.cmd_batch([Stdlib.cmd_none()]) == {:cmd, {:batch, [:none]}}
    end

    test "a store form without its model: nil, and Store reads an error" do
      cb = Rt.ctor("R.Msg", "Loaded", 1)
      assert Stdlib.cmd_store_list(cb) == {:cmd, {:effect, "Cmd.store.list", nil, [cb]}}

      assert {:nobi_error, "`Store.get` " <> _} = error(fn -> Stdlib.store_get(:s, uuid(@id)) end)
      assert {:nobi_error, "`Store.list` " <> _} = error(fn -> Stdlib.store_list(:s) end)
    end

    test "Tx ops are tagged tuples; insert and update without their model here" do
      row = rec("C.Row", text: "t")

      assert [
               Stdlib.tx_insert(row),
               Stdlib.tx_update(uuid(@id), row),
               Stdlib.tx_delete("C.Row", uuid(@id))
             ] ==
               [
                 {:tx, :insert, nil, row},
                 {:tx, :update, nil, uuid(@id), row},
                 {:tx, :delete, "C.Row", uuid(@id)}
               ]
    end

    test "a Tx op compares as the variant its call reads as" do
      row = rec("C.Row", text: "t")
      ins = {:tx, :insert, "C.Row", row}
      del = {:tx, :delete, "C.Row", uuid(@id)}
      assert Rt.tx_variant(ins) == {:var, "Tx", "insert", [row]}
      assert Rt.tx_variant(del) == {:var, "Tx", "delete", ["C.Row", uuid(@id)]}
      assert Rt.compare(ins, ins) == :eq
      assert Rt.compare(del, ins) == Rt.compare(Rt.tx_variant(del), Rt.tx_variant(ins))
      assert Rt.compare(del, ins) == :lt
      assert Rt.kind_name(ins) == "a variant"
      assert Rt.eq(ins, {:tx, :insert, "C.Row", row})
    end

    test "a Store handle is its own kind, and comparing handles is a runtime error" do
      store = {:store, self(), make_ref()}
      assert Rt.kind_name(store) == "a Store"
      assert {:nobi_error, message} = catch_throw(Rt.compare(store, store))
      assert message =~ "Store"
      assert {:nobi_error, _} = catch_throw(Rt.compare([store], [store]))
      assert Rt.eq(store, store)
    end

    test "JSON applied as a value" do
      assert Stdlib.json_parse("1") ==
               {:var, "Result", "Err",
                ["JSON.parse has no type to decode into when applied as a value"]}

      assert Stdlib.json_stringify([1]) == {:var, "Result", "Ok", ["[1]"]}
    end
  end

  describe "the walk budget" do
    # `[x, x]` forty times over: forty-one nodes in memory, 2^41 - 1 to walk.
    defp doubled(n), do: Enum.reduce(1..n, [1], fn _, x -> [x, x] end)

    test "weight counts as Rust's does, and stops at the cap" do
      assert Rt.weight(1, 10) == 1
      assert Rt.weight(String.duplicate("a", 128), 10) == 3
      assert Rt.weight([1, 2], 10) == 3
      assert Rt.weight(%{"a" => 1}, 10) == 3
      assert Rt.weight({:rec, "M", %{"x" => 1}}, 10) == 2
      assert Rt.weight({:var, "O", "V", [1, 2]}, 10) == 3
      assert Rt.weight({:cmd, {:batch, [:none, {:effect, "Cmd.time.now", nil, [1]}]}}, 10) == 2
      assert Rt.weight(doubled(2), 100) == 11
      assert Rt.weight(doubled(40), 1_000) == 1_000
    end

    test "eq, compare and map keys past the budget throw Rust's error" do
      big = doubled(40)
      out = {:nobi_error, "evaluation took more than 1000000 steps"}
      assert catch_throw(Rt.eq(big, big)) == out
      assert catch_throw(Rt.compare(big, doubled(40))) == out
      assert catch_throw(Rt.map_from_list([{big, 1}])) == out
      assert catch_throw(Rt.sorted_entries(%{big => 1, [big] => 2})) == out
    end

    test "within the budget they answer as before" do
      assert Rt.eq(doubled(10), doubled(10))
      assert Rt.compare(doubled(10), doubled(11)) == :lt

      assert Rt.map_from_list([{"a", 1}, {"a", 2}, {doubled(3), 3}]) == %{
               "a" => 2,
               doubled(3) => 3
             }

      # A lighter side bounds the walk: comparing with a small value is cheap.
      refute Rt.eq(doubled(40), [1])
    end
  end
end
