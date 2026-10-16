defmodule Kinoko.Lang.RtJsonTest do
  # Ported from kinoko-next `tests/interp_stdlib.rs` (JSON.parse and
  # JSON.stringify sections), at the Rt level: `Rt.Json.parse(text, T,
  # models)` where `T` is the call's target type (the `T` of its
  # `Result<T, String>`), and `Rt.Json.stringify(v, type, models)`.
  use ExUnit.Case, async: true

  alias Kinoko.Lang.Rt
  alias Kinoko.Lang.Rt.Json

  @id "0b9e2c4a-1f3d-4e5f-8a7b-6c5d4e3f2a1b"
  @max 9_223_372_036_854_775_807
  @min -9_223_372_036_854_775_808

  defp n(name), do: {:named, name}

  # The image's model table (`__yabu__(:models)`) from `{field, type}`
  # lists: no field here has a default.
  defp table(models) do
    Map.new(models, fn {model, fields} ->
      {model, Enum.map(fields, fn {f, t} -> {f, t, :none} end)}
    end)
  end

  defp l(t), do: {:applied, "List", [t]}
  defp o(t), do: {:applied, "Option", [t]}
  defp m(k, v), do: {:applied, "Map", [k, v]}
  defp t(items), do: {:tuple, items}

  defp some(v), do: {:var, "Option", "Some", [v]}
  defp none, do: {:var, "Option", "None", []}
  defp rec(model, fields), do: {:rec, model, Map.new(fields)}
  defp uuid(s), do: {:uuid, s}

  @models %{
    "J.Inner" => [{"n", {:named, "Int"}}],
    "J.Rec" => [
      {"s", {:named, "String"}},
      {"n", {:named, "Int"}},
      {"b", {:named, "Bool"}},
      {"opt", {:applied, "Option", [{:named, "Int"}]}},
      {"items", {:applied, "List", [{:named, "Int"}]}},
      {"inner", {:named, "J.Inner"}}
    ]
  }

  # `Ok`'s value, or `Err`'s reason.
  defp decode(text, ty, models \\ @models) do
    case Json.parse(text, ty, table(models)) do
      {:var, "Result", "Ok", [v]} -> {:ok, v}
      {:var, "Result", "Err", [why]} when is_binary(why) -> {:error, why}
    end
  end

  defp stringify(v, models \\ @models) do
    case Json.stringify(v, nil, table(models)) do
      {:var, "Result", "Ok", [s]} when is_binary(s) -> {:ok, s}
      {:var, "Result", "Err", [why]} when is_binary(why) -> {:error, why}
    end
  end

  # ---------- JSON.parse ----------

  test "Int accepts integers" do
    assert decode("42", n("Int")) == {:ok, 42}
    assert decode("-7", n("Int")) == {:ok, -7}
    assert decode("0", n("Int")) == {:ok, 0}

    for bad <- ~w(1.5 "1" "42" true false null {} [1] [] 1e21 1.0000000001 1e999) do
      assert {:error, _} = decode(bad, n("Int")), "Int must reject #{bad}"
    end
  end

  test "String / Bool are strict" do
    assert decode(~s("hi"), n("String")) == {:ok, "hi"}

    for bad <- ~w(42 true null {} [] 1.5),
        do: assert({:error, _} = decode(bad, n("String")), bad)

    assert decode("true", n("Bool")) == {:ok, true}

    for bad <- ~w(1 0 "true" null {} []),
        do: assert({:error, _} = decode(bad, n("Bool")), bad)
  end

  test "Option: null is None, a value is Some, a wrong inner is Err" do
    assert decode("null", o(n("Int"))) == {:ok, none()}
    assert decode("5", o(n("Int"))) == {:ok, some(5)}

    for bad <- ~w("x" 1.5 true {} [1]),
        do: assert({:error, _} = decode(bad, o(n("Int"))), bad)
  end

  test "List rejects non-arrays and any bad element" do
    assert decode("[]", l(n("Int"))) == {:ok, []}
    assert decode("[1,2,3]", l(n("Int"))) == {:ok, [1, 2, 3]}

    for bad <- ~w(5 "x" null {} [1,"x"] [1.5] [null] [[1]]),
        do: assert({:error, _} = decode(bad, l(n("Int"))), bad)
  end

  test "record: exact shape, nested records built, extras dropped" do
    text = ~s({"s":"a","n":1,"b":true,"opt":null,"items":[1,2],"inner":{"n":9}})
    inner = rec("J.Inner", [{"n", 9}])

    record = fn opt, items ->
      rec("J.Rec", [
        {"s", "a"},
        {"n", 1},
        {"b", true},
        {"opt", opt},
        {"items", items},
        {"inner", inner}
      ])
    end

    assert decode(text, n("J.Rec")) == {:ok, record.(none(), [1, 2])}
    extra = ~s({"s":"a","n":1,"b":true,"opt":5,"items":[],"inner":{"n":9},"HACK":"x"})
    assert decode(extra, n("J.Rec")) == {:ok, record.(some(5), [])}
  end

  test "record: every missing field, wrong type or wrong container is Err" do
    good = ~s({"s":"a","n":1,"b":true,"opt":null,"items":[],"inner":{"n":0}})
    assert {:ok, _} = decode(good, n("J.Rec"))

    for bad <- [
          ~s({"n":1,"b":true,"opt":null,"items":[],"inner":{"n":0}}),
          ~s({"s":"a","b":true,"opt":null,"items":[],"inner":{"n":0}}),
          ~s({"s":1,"n":1,"b":true,"opt":null,"items":[],"inner":{"n":0}}),
          ~s({"s":"a","n":1.5,"b":true,"opt":null,"items":[],"inner":{"n":0}}),
          ~s({"s":"a","n":1,"b":1,"opt":null,"items":[],"inner":{"n":0}}),
          ~s({"s":"a","n":1,"b":true,"opt":null,"items":"no","inner":{"n":0}}),
          ~s({"s":"a","n":1,"b":true,"opt":null,"items":["x"],"inner":{"n":0}}),
          ~s({"s":"a","n":1,"b":true,"opt":null,"items":[],"inner":{"n":"x"}}),
          ~s({"s":"a","n":1,"b":true,"opt":null,"items":[],"inner":{}}),
          ~s({"s":"a","n":1,"b":true,"opt":null,"items":[],"inner":5}),
          "[1,2,3]",
          "null",
          "42",
          ~s("x"),
          "true",
          "not json"
        ] do
      assert {:error, _} = decode(bad, n("J.Rec")), bad
    end
  end

  test "a number reads as an Int exactly" do
    for {text, v} <- [
          {"9007199254740993", 9_007_199_254_740_993},
          {"9223372036854775807", @max},
          {"-9223372036854775808", @min},
          {"1.0", 1},
          {"1e3", 1000},
          {"1E+2", 100},
          {"10e-1", 1},
          {"1.50e1", 15},
          {"0.5e1", 5},
          {"-0", 0},
          {"0e999999999999999999999", 0},
          {" \t\n\r7\r\n", 7},
          {"0e30", 0},
          {"-0e19", 0}
        ] do
      assert decode(text, n("Int")) == {:ok, v}, text
    end

    for bad <- [
          "9223372036854775808",
          "-9223372036854775809",
          "1e-400",
          "1.0000000000000000001",
          "1e19",
          "0.55e1",
          "1e9223372036854775807",
          "1e99999999999999999999",
          "-1e99999999999999999999",
          "1e-99999999999999999999"
        ] do
      assert decode(bad, n("Int")) == {:error, "expected Int at $"}, bad
    end
  end

  test "any number the grammar allows reads without overflow" do
    for _ <- 1..500 do
      num = random_number()
      v = decode(num, n("Int"))
      assert match?({:ok, _}, v) or v == {:error, "expected Int at $"}, "#{num}: #{inspect(v)}"
    end

    for _ <- 1..300 do
      x = Enum.random(@min..@max)
      k = Enum.random(0..38)
      p = Integer.pow(10, k)

      exact =
        if x * p >= @min and x * p <= @max, do: {:ok, x * p}, else: {:error, "expected Int at $"}

      assert decode("#{x}e#{k}", n("Int")) == exact
      assert decode("#{x}.#{String.duplicate("0", k + 1)}", n("Int")) == {:ok, x}

      if x != 0,
        do: assert(decode("#{x}#{String.duplicate("0", k)}e-#{k}", n("Int")) == {:ok, x})
    end
  end

  defp random_number do
    digits = fn len -> for(_ <- 1..len, into: "", do: <<Enum.random(?0..?9)>>) end
    sign = Enum.random(["", "-"])

    whole =
      Enum.random(["0", Integer.to_string(Enum.random(1..9)) <> digits.(Enum.random(1..24))])

    frac = Enum.random(["", "." <> digits.(Enum.random(1..24))])

    exp =
      Enum.random([
        "",
        Enum.random(["e", "E"]) <> Enum.random(["", "+", "-"]) <> digits.(Enum.random(1..24))
      ])

    sign <> whole <> frac <> exp
  end

  test "parse gives TS's reason and path" do
    nested = l(t([n("Int"), o(l(n("String")))]))

    for {ty, text, why} <- [
          {l(n("Int")), ~s([1,"x"]), "expected Int at $[1]"},
          {n("String"), "1", "expected String at $"},
          {n("Bool"), "1", "expected Bool at $"},
          {n("Uuid"), ~s("0B9E2C4A-1F3D-4E5F-8A7B-6C5D4E3F2A1B"), "expected Uuid at $"},
          {l(n("Int")), "{}", "expected array at $"},
          {t([n("Int"), n("String")]), "[1]", "expected 2-tuple at $"},
          {t([n("Int"), n("String")]), ~s([1,"a",3]), "expected 2-tuple at $"},
          {nested, ~s([[1,["a",2]]]), "expected String at $[0].1[1]"},
          {nested, ~s([[1,null],[2]]), "expected 2-tuple at $[1]"}
        ] do
      assert decode(text, ty) == {:error, why}, text
    end

    assert decode(~s("#{@id}"), n("Uuid")) == {:ok, uuid(@id)}

    assert decode(~s([[1,null],[2,["a"]]]), nested) ==
             {:ok, [{1, none()}, {2, some(["a"])}]}

    assert decode(~s({"a":1,"a":2}), m(n("String"), n("Int"))) == {:ok, %{"a" => 2}}
    assert decode(~s([["a",1]]), m(n("String"), n("Int"))) == {:error, "expected Map at $"}
  end

  test "parse reads each map key kind" do
    assert decode(~s({"a":1,"b":2}), m(n("String"), n("Int"))) == {:ok, %{"a" => 1, "b" => 2}}

    assert decode(~s({"#{@id}":"x"}), m(n("Uuid"), n("String"))) ==
             {:ok, %{uuid(@id) => "x"}}

    assert decode(~s({"-1":"a","3":"c"}), m(n("Int"), n("String"))) ==
             {:ok, %{-1 => "a", 3 => "c"}}

    assert decode(~s({"true":"y","false":"n"}), m(n("Bool"), n("String"))) ==
             {:ok, %{false => "n", true => "y"}}

    assert decode(~S({"[1,\"a\"]":"x"}), m(t([n("Int"), n("String")]), n("String"))) ==
             {:ok, %{{1, "a"} => "x"}}

    assert decode(~S({"{\"n\":9}":"z"}), m(n("J.Inner"), n("String"))) ==
             {:ok, %{rec("J.Inner", [{"n", 9}]) => "z"}}
  end

  test "one key written two ways keeps the text sorting last" do
    ty = m(t([n("Int"), n("Bool")]), n("String"))
    a = {:ok, %{{1, true} => "a"}}
    assert decode(~s({"[1,true]":"a","[1, true]":"b"}), ty) == a
    assert decode(~s({"[1, true]":"b","[1,true]":"a"}), ty) == a
  end

  test "a bad map key is Err named for the entry" do
    tuple_key = t([n("Int"), n("String")])

    for {ty, text, why} <- [
          {m(n("Int"), n("String")), ~s({"x":"a"}), ~s|expected Int at $["x"] (a map key)|},
          {m(n("Int"), n("String")), ~s({"true":"a"}), ~s|expected Int at $["true"] (a map key)|},
          {m(n("Bool"), n("String")), ~s({"x":"a"}), ~s|expected Bool at $["x"] (a map key)|},
          {m(n("Uuid"), n("String")), ~s({"not-a-uuid":"a"}),
           ~s|expected Uuid at $["not-a-uuid"] (a map key)|},
          {m(tuple_key, n("String")), ~s({"[1]":"a"}),
           ~s|expected 2-tuple at $["[1]"] (a map key)|},
          {m(tuple_key, n("String")), ~s({"x":"a"}),
           ~s|expected (Int, String) at $["x"] (a map key)|},
          {m(tuple_key, n("String")), ~s({"[1,2]":"a"}),
           ~s|expected String at $["[1,2]"].1 (a map key)|},
          {m(n("J.Inner"), n("String")), ~s({"{}":"a"}),
           ~s|missing field 'n' at $["{}"] (a map key)|},
          {m(n("J.Inner"), n("String")), ~s({"[1]":"a"}),
           ~s|expected object at $["[1]"] for J.Inner (a map key)|}
        ] do
      assert decode(text, ty) == {:error, why}, text
    end
  end

  test "a map key nested past the depth limit is refused" do
    key = String.duplicate("[", 100_001) <> String.duplicate("]", 100_001)
    text = ~s({"#{key}":"x"})
    why = ~s|nested deeper than 100000 levels at $["#{key}"] (a map key)|
    assert decode(text, m(l(n("Int")), n("String"))) == {:error, why}
  end

  test "a variant-keyed map is Err" do
    key = ~s({"$variant":"J.Shape.Dot","values":[]})
    text = ~s({"#{String.replace(key, "\"", "\\\"")}":1})

    why =
      ~s|cannot decode 'J.Shape' from JSON at $["#{String.replace(key, "\"", "\\\"")}"] (a map key)|

    assert decode(text, m(n("J.Shape"), n("Int"))) == {:error, why}
  end

  test "a bad key inside a map-keyed map names it once" do
    inner_key = ~s({"x":"a"})
    escaped = String.replace(inner_key, "\"", "\\\"")
    text = ~s({"#{escaped}":"v"})
    why = ~s|expected Int at $["#{escaped}"]["x"] (a map key)|
    assert decode(text, m(m(n("Int"), n("String")), n("String"))) == {:error, why}
  end

  test "parse into what is not data is Err" do
    for {ty, text, why} <- [
          {{:applied, "Html", [n("J.Shape")]}, ~s({"$h":"p","at":[],"ch":[]}),
           "cannot decode 'Html' from JSON at $"},
          {{:applied, "Cmd", [n("J.Shape")]}, ~s({"$c":"none"}),
           "cannot decode 'Cmd' from JSON at $"},
          {{:arrow, [n("Int")], n("Int")}, "{}", "cannot decode at $"},
          {n("J.Shape"), ~s({"$variant":"J.Shape.Dot","values":[]}),
           "cannot decode 'J.Shape' from JSON at $"},
          {{:applied, "Result", [n("Int"), n("String")]},
           ~s({"$variant":"Result.Ok","values":[1]}), "cannot decode 'Result' from JSON at $"}
        ] do
      assert decode(text, ty) == {:error, why}, text
    end
  end

  test "no target type, or an open one, is Err" do
    assert decode("1", nil) ==
             {:error, "JSON.parse has no type to decode into when applied as a value"}

    assert decode("[1]", l({:var, "a"})) ==
             {:error, "JSON.parse needs its target type: write (JSON.parse(s) : T)"}
  end

  test "a lone surrogate into a string is Err" do
    lone = fn at -> {:error, "invalid JSON: a lone surrogate escape at byte #{at}"} end
    assert decode(~S("\ud800"), n("String")) == lone.(1)
    assert decode(~S("\udc00"), n("String")) == lone.(1)
    assert decode(~S("a\ud83d"), n("String")) == lone.(2)
    assert decode(~S("\ud83dA"), n("String")) == lone.(1)
    assert decode(~S("👋"), n("String")) == {:ok, "👋"}
  end

  test "text that is not JSON is Err" do
    for bad <- [
          "",
          " ",
          "not json",
          "[1,",
          "[1,]",
          ~s({"a":1,}),
          "01",
          "1.",
          ".5",
          "+1",
          "-",
          "1e",
          ~s("a),
          ~S("\x"),
          "'a'",
          "[1] 2",
          "nul",
          "\"\u0001\"",
          "{1:2}",
          ~S("\ud800"),
          ~S("\udc00\ud800"),
          "NaN",
          "Infinity"
        ] do
      assert {:error, "invalid JSON: " <> _} = decode(bad, l(n("Int"))), inspect(bad)
    end

    assert decode(~S("👋 é\n\/"), n("String")) == {:ok, "👋 é\n/"}
  end

  test "the reasons for text that is not JSON" do
    assert decode("", l(n("Int"))) == {:error, "invalid JSON: unexpected end of text"}
    assert decode("not json", l(n("Int"))) == {:error, "invalid JSON: unexpected 'n' at byte 0"}
    assert decode("[1,]", l(n("Int"))) == {:error, "invalid JSON: unexpected ']' at byte 3"}
    assert decode(~s("a), n("String")) == {:error, "invalid JSON: unterminated string"}
    assert decode("[1] é", l(n("Int"))) == {:error, "invalid JSON: unexpected 'é' at byte 4"}
    assert decode("\"\n\"", n("String")) == {:error, "invalid JSON: unexpected '\\n' at byte 1"}
  end

  test "JSON nested past the depth limit is refused" do
    deep = fn levels -> String.duplicate("[", levels) <> String.duplicate("]", levels) end
    assert decode(deep.(100_000), l(n("Int"))) == {:error, "expected Int at $[0]"}

    assert decode(deep.(100_001), l(n("Int"))) ==
             {:error, "invalid JSON: nested deeper than 100000 levels"}

    chain = fn levels ->
      Enum.reduce(2..levels//1, Rt.variant("A.T", "Leaf", []), fn _, inner ->
        Rt.variant("A.T", "Node", [inner])
      end)
    end

    {:ok, text} = stringify(chain.(100_000))
    assert String.starts_with?(text, ~s({"$variant":"A.T.Node","values":[{))
    assert String.ends_with?(text, "]}]}")

    assert catch_throw(stringify(chain.(100_001))) ==
             {:yabu_error, "JSON.stringify: value nested deeper than 100000 levels"}
  end

  # ---------- JSON.stringify ----------

  test "stringify: clean JSON out, model dropped, Option unwrapped" do
    record =
      rec("J.Rec", [
        {"s", "a"},
        {"n", 1},
        {"b", true},
        {"opt", some(5)},
        {"items", [1]},
        {"inner", rec("J.Inner", [{"n", 9}])}
      ])

    assert stringify(record) ==
             {:ok, ~s({"s":"a","n":1,"b":true,"opt":5,"items":[1],"inner":{"n":9}})}
  end

  test "stringify writes TS's text" do
    for {v, text} <- [
          {-5, "-5"},
          {true, "true"},
          {{1, "a", true}, ~s([1,"a",true])},
          {[some(1), none()], "[1,null]"},
          {some(none()), "null"},
          {Rt.variant("J.Shape", "Circle", [3]), ~s({"$variant":"J.Shape.Circle","values":[3]})},
          {Rt.variant("J.Shape", "Dot", []), ~s({"$variant":"J.Shape.Dot","values":[]})},
          {Rt.variant("J.Shape", "Pair", [1, "z"]),
           ~s({"$variant":"J.Shape.Pair","values":[1,"z"]})},
          {Rt.variant("Result", "Ok", [1]), ~s({"$variant":"Result.Ok","values":[1]})},
          {"q\"\\ \n\t\r", ~S("q\"\\ \n\t\r")}
        ] do
      assert stringify(v) == {:ok, text}, inspect(v)
    end

    s = "\u0008\u000C\u0001\u001F\u007F\u0085\u00A0\u2028\u2029\uFEFFé👋/<>&'"
    text = "\"\\b\\f\\u0001\\u001f\u007F\u0085\u00A0\u2028\u2029\uFEFFé👋/<>&'\""
    assert stringify(s) == {:ok, text}
    assert stringify({uuid(@id), @min}) == {:ok, ~s(["#{@id}",#{@min}])}
  end

  test "stringify writes each map key kind" do
    for {v, text} <- [
          {%{"a" => 1, "b" => 2}, ~s({"a":1,"b":2})},
          {%{1 => "a"}, ~s({"1":"a"})},
          {%{true => 1}, ~s({"true":1})},
          {%{{1, 2} => "x"}, ~s({"[1,2]":"x"})},
          {%{[1, 2] => "x"}, ~s({"[1,2]":"x"})},
          {%{rec("J.Inner", [{"n", 9}]) => "z"}, ~S({"{\"n\":9}":"z"})},
          {%{Rt.variant("J.Shape", "Dot", []) => 1},
           ~S({"{\"$variant\":\"J.Shape.Dot\",\"values\":[]}":1})},
          {%{%{1 => "a"} => "x"}, ~S({"{\"1\":\"a\"}":"x"})},
          {%{uuid(@id) => "x"}, ~s({"#{@id}":"x"})}
        ] do
      assert stringify(v) == {:ok, text}, inspect(v)
    end
  end

  test "map stringify follows Yabu key order for large maps" do
    m = Map.new(1..40, &{&1, &1})
    ty = {:applied, "Map", [{:named, "Int"}, {:named, "Int"}]}
    shuffled = Map.new(Enum.shuffle(1..40), &{&1, &1})
    assert Json.stringify(m, ty, %{}) == Json.stringify(shuffled, ty, %{})
    {:var, "Result", "Ok", [text]} = Json.stringify(m, ty, %{})
    assert text =~ ~r/^\{"1":1,"2":2/

    assert stringify(%{3 => "c", -1 => "a"}) == {:ok, ~s({"-1":"a","3":"c"})}
    assert stringify(%{2 => "a", 10 => "b"}) == {:ok, ~s({"2":"a","10":"b"})}
  end

  test "stringify writes a Tx op as the variant it is, and refuses a Store" do
    models = %{"T.Row" => [{"id", n("Uuid")}, {"text", n("String")}]}
    row = rec("T.Row", [{"text", "t"}])

    assert stringify({:tx, :insert, "T.Row", row}, models) ==
             {:ok, ~s({"$variant":"Tx.insert","values":[{"text":"t"}]})}

    assert stringify({:tx, :update, "T.Row", uuid(@id), row}, models) ==
             {:ok, ~s({"$variant":"Tx.update","values":["#{@id}",{"text":"t"}]})}

    assert stringify({:tx, :delete, "T.Row", uuid(@id)}, models) ==
             {:ok, ~s({"$variant":"Tx.delete","values":["T.Row","#{@id}"]})}

    assert stringify([{:store, self(), make_ref()}], models) ==
             {:error, "cannot encode a Store as JSON at $[0]"}
  end

  test "Unit is written as the empty tuple" do
    assert stringify({}) == {:ok, "[]"}
    assert stringify([{}]) == {:ok, "[[]]"}
  end

  test "a record's fields are written in its model's order, then the rest by name" do
    models = %{"J.P" => [{"s", n("String")}, {"n", n("Int")}]}
    assert stringify(rec("J.P", [{"n", 1}, {"s", "x"}]), models) == {:ok, ~s({"s":"x","n":1})}
    assert stringify(rec("J.P", [{"n", 1}]), models) == {:ok, ~s({"n":1})}

    assert stringify(rec("J.P", [{"z", 0}, {"a", 2}, {"s", "x"}]), models) ==
             {:ok, ~s({"s":"x","a":2,"z":0})}

    assert decode(~s({"text":"t"}), n("T.Row"), %{
             "T.Row" => [{"id", n("Uuid")}, {"text", n("String")}]
           }) ==
             {:error, "missing field 'id' at $"}
  end

  test "stringify of a function, a Cmd or Html is Err" do
    p = Rt.html_element("p", [], ["hi"])

    for {v, why} <- [
          {fn x -> x end, "cannot encode a function as JSON at $"},
          {Rt.ctor("J.Msg", "Got", 1), "cannot encode a function as JSON at $"},
          {[Rt.cmd_none()], "cannot encode a Cmd as JSON at $[0]"},
          {{1, Rt.cmd_effect("Cmd.time.now", nil, [])}, "cannot encode a Cmd as JSON at $.1"},
          {p, "cannot encode Html as JSON at $"},
          {some([p]), "cannot encode Html as JSON at $[0]"},
          {rec("J.Inner", [{"n", fn -> 1 end}]), "cannot encode a function as JSON at $.n"},
          {Rt.variant("J.T", "V", [1, p]), "cannot encode Html as JSON at $.values[1]"},
          {%{1 => p}, ~s(cannot encode Html as JSON at $["1"])}
        ] do
      assert stringify(v) == {:error, why}, inspect(v)
    end
  end

  # ---------- the round trip ----------

  test "parse of stringify gives the value back" do
    models = %{
      "J.Inner" => [{"id", n("Uuid")}, {"n", n("Int")}],
      "J.Rec" => [
        {"s", n("String")},
        {"opt", o(n("J.Inner"))},
        {"items", l(n("J.Inner"))},
        {"pair", t([n("Bool"), m(n("Int"), n("String"))])}
      ]
    }

    inner = fn -> rec("J.Inner", [{"id", random_uuid()}, {"n", random_int()}]) end

    gens = [
      {l(n("Int")), fn -> random_ints() end},
      {t([n("String"), n("Bool"), o(n("Int"))]),
       fn -> {random_string(), Enum.random([true, false]), random_option(&random_int/0)} end},
      {m(n("String"), l(n("Int"))), fn -> random_map(&random_string/0, &random_ints/0) end},
      {m(t([n("Int"), n("String")]), o(n("String"))),
       fn ->
         random_map(fn -> {random_int(), random_string()} end, fn ->
           random_option(&random_string/0)
         end)
       end},
      {l(o(n("Uuid"))),
       fn -> for _ <- 0..Enum.random(0..4), do: random_option(&random_uuid/0) end},
      {m(n("Int"), n("String")), fn -> random_map(&random_int/0, &random_string/0) end},
      {m(n("Bool"), n("String")),
       fn -> random_map(fn -> Enum.random([true, false]) end, &random_string/0) end},
      {m(n("J.Inner"), n("String")), fn -> random_map(inner, &random_string/0) end},
      {m(n("Uuid"), n("String")), fn -> random_map(&random_uuid/0, &random_string/0) end},
      {m(l(n("Int")), n("String")), fn -> random_map(&random_ints/0, &random_string/0) end},
      {m(m(n("Int"), n("String")), n("String")),
       fn ->
         random_map(fn -> random_map(&random_int/0, &random_string/0) end, &random_string/0)
       end},
      {n("J.Rec"),
       fn ->
         rec("J.Rec", [
           {"s", random_string()},
           {"opt", random_option(inner)},
           {"items", for(_ <- 1..Enum.random(1..4)//1, do: inner.())},
           {"pair", {Enum.random([true, false]), random_map(&random_int/0, &random_string/0)}}
         ])
       end}
    ]

    for {ty, gen} <- gens, _ <- 1..60 do
      v = gen.()
      {:var, "Result", "Ok", [text]} = Json.stringify(v, ty, table(models))

      assert Json.parse(text, ty, table(models)) == {:var, "Result", "Ok", [v]},
             inspect({ty, v, text})
    end
  end

  test "awkward strings round-trip" do
    ty = t([n("String"), n("Bool"), o(n("Int"))])

    for s <- [
          "",
          "say \"hi\"\n",
          "back\\slash\t\r",
          "\u0000\u0001\u001F\u007F",
          "é👋\u2028\uFEFF",
          "\\u0041"
        ] do
      v = {s, false, none()}
      {:var, "Result", "Ok", [text]} = Json.stringify(v, ty, %{})
      assert Json.parse(text, ty, %{}) == {:var, "Result", "Ok", [v]}, inspect(s)
    end
  end

  defp random_int,
    do: Enum.random([0, 1, -1, @max, @min, Enum.random(-1000..1000), Enum.random(@min..@max)])

  defp random_ints, do: for(_ <- 1..Enum.random(1..8)//1, do: random_int()) |> Enum.drop(1)

  defp random_string do
    pool = ~c"ab\"\\\n\t\u0000\u001f é👋\u2028{}[],:"
    for _ <- 1..Enum.random(0..8)//1, into: "", do: <<Enum.random(pool)::utf8>>
  end

  defp random_uuid do
    hex = fn len -> for _ <- 1..len, into: "", do: <<Enum.random(~c"0123456789abcdef")>> end
    uuid(Enum.join([hex.(8), hex.(4), hex.(4), hex.(4), hex.(12)], "-"))
  end

  defp random_option(gen), do: if(Enum.random([true, false]), do: some(gen.()), else: none())

  defp random_map(k, v),
    do: Map.new(1..Enum.random(1..5)//1, fn _ -> {k.(), v.()} end) |> drop_some()

  defp drop_some(map), do: if(Enum.random([true, false]), do: map, else: %{})
end
