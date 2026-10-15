defmodule Kinoko.Exec.ShowTest do
  # Round trips load images: not async.
  use ExUnit.Case, async: false

  alias Kinoko.Exec
  alias Kinoko.Exec.Show
  alias Kinoko.Lang
  alias Kinoko.Lang.{Format, Parser, Rt}

  # kinoko-next `interp/value.rs`'s `rust_only_display_*` tests: a value is
  # spelled as the formatter spells the literal that builds it.

  @id "0b9e2c4a-1f3d-4e5f-8a7b-6c5d4e3f2a1b"

  defp var(owner, variant, args \\ []), do: {:var, owner, variant, args}
  defp text(s), do: var("Html", "Text", [s])
  defp element(tag, attrs, children), do: var("Html", "Element", [tag, attrs, children])

  defp universe(src) do
    {u, r} = Lang.stage(Lang.new(), "p", src)
    assert {:promoted, _} = r, inspect(r)
    Lang.snapshot(u)
  end

  # How long `Show.show/1` took to write `v`, in ms, and what it wrote.
  defp shown_quickly(v) do
    {us, shown} = :timer.tc(fn -> Show.show(v) end)
    assert us < 2_000_000, "took #{us} µs"
    shown
  end

  test "each kind is written as a literal" do
    u = universe("def M.f(n : Int) : Int do n end")
    {:ok, image} = Exec.load(u)
    {f, 1} = image.names["M.f"]
    {:ok, closure, _} = Exec.eval(u, "fn () -> 1 end")
    {:ok, from_int, _} = Exec.eval(u, "String.from_int")

    cases = [
      {-3, "-3"},
      {"say \"hi\"\n", ~S("say \"hi\"\n")},
      {true, "true"},
      {{:uuid, @id}, "<uuid #{@id}>"},
      {[1, 2], "[1, 2]"},
      {[], "[]"},
      {%{"b" => 2, "a" => 1}, ~S(%{"a" => 1, "b" => 2})},
      {%{}, "%{}"},
      {{1, "x"}, ~S|(1, "x")|},
      {{}, "()"},
      {{:rec, "M.Model", %{"count" => 1, "by" => "me"}}, ~S(%M.Model{by: "me", count: 1})},
      {var("M.Msg", "Add", [1]), "M.Msg.Add(1)"},
      {var("Option", "None"), "Option.None"},
      {var("Option", "Some", [var("Option", "None")]), "Option.Some(Option.None)"},
      {Function.capture(image.module, f, 1), "<fn M.f>"},
      {from_int, "<fn String.from_int>"},
      {Rt.ctor("M.Msg", "Add", 1), "<fn M.Msg.Add>"},
      {closure, "<fn>"},
      {{:cmd, :none}, "Cmd.none()"},
      {{:cmd, {:batch, [:none, :none]}}, "Cmd.batch([Cmd.none(), Cmd.none()])"},
      {{:cmd, {:effect, "Cmd.store.insert", nil, ["x", Rt.ctor("M.Msg", "Saved", 1)]}},
       ~S|Cmd.store.insert("x", <fn M.Msg.Saved>)|},
      # A store read's model is its callback's type's, as in source.
      {{:cmd, {:effect, "Cmd.store.list", "M.Row", [Rt.ctor("M.Msg", "Rows", 1)]}},
       "Cmd.store.list(<fn M.Msg.Rows>)"},
      {var("Tx", "insert", [{:rec, "C.Row", %{"text" => "t"}}]), ~S|Tx.insert(%C.Row{text: "t"})|}
    ]

    for {value, want} <- cases do
      assert Show.show(value) == want, inspect(value)
      assert Exec.show(value, nil) == want
    end
  end

  test "Html is written as JSX" do
    button =
      element("button", [{"class", "big"}, {"on-click", var("M.Msg", "Inc")}, {"n", 1}], [
        text("+")
      ])

    page =
      element("div", [], [
        text("Count:"),
        text(" 3"),
        text("a<b"),
        button,
        element("br", [], [])
      ])

    assert Show.show(page) == """
           <div>
             Count:
             {" 3"}
             {"a<b"}
             <button class="big" on-click={M.Msg.Inc} n={1}>+</button>
             <br />
           </div>\
           """

    # A text node on its own has no JSX spelling: it is the variant.
    assert Show.show(text("hi")) == ~S|Html.Text("hi")|
  end

  test "literals are spelled as the formatter spells them" do
    cases = [
      {"[1, -2]", [1, -2]},
      {~S(%{"a" => 1}), %{"a" => 1}},
      {~S|(1, "x")|, {1, "x"}},
      {"%M.Model{count: 1}", {:rec, "M.Model", %{"count" => 1}}},
      {"M.Msg.Add(1)", var("M.Msg", "Add", [1])},
      {"Option.None", var("Option", "None")},
      {~S("tab\t, quote\", backslash\\, é"), "tab\t, quote\", backslash\\, é"},
      {"Cmd.batch([Cmd.none()])", {:cmd, {:batch, [:none]}}},
      {~S(<p class="x" n={1}>hi</p>), element("p", [{"class", "x"}, {"n", 1}], [text("hi")])},
      {"<button on-click={M.Msg.Inc}>+</button>",
       element("button", [{"on-click", var("M.Msg", "Inc")}], [text("+")])},
      {"<div><p>hi</p></div>", element("div", [], [element("p", [], [text("hi")])])},
      {~S(<p class="a-long-list-of-utility-classes">Some text that runs on for quite a while{" more"}</p>),
       element("p", [{"class", "a-long-list-of-utility-classes"}], [
         text("Some text that runs on for quite a while"),
         text(" more")
       ])},
      {"<p>one\ntwo</p>", element("p", [], [text("one\ntwo")])}
    ]

    for {src, value} <- cases do
      {:ok, e} = Parser.expr(src)
      assert Show.show(value) == Format.expr(e), src
    end
  end

  test "a deep value stops at the depth cap" do
    lists = shown_quickly(Enum.reduce(1..100_000, 0, fn _, inner -> [inner] end))
    assert lists == String.duplicate("[", 64) <> "…" <> String.duplicate("]", 64)

    chain =
      shown_quickly(
        Enum.reduce(1..100_000, var("M.T", "Leaf"), fn _, inner -> var("M.T", "S", [inner]) end)
      )

    assert chain == String.duplicate("M.T.S(", 64) <> "…" <> String.duplicate(")", 64)

    html =
      shown_quickly(
        Enum.reduce(1..10_000, text("x"), fn _, inner -> element("b", [], [inner]) end)
      )

    assert length(String.split(html, "<b>")) - 1 == 64
    assert length(String.split(html, "{…}")) - 1 == 1 and byte_size(html) < 20_000
  end

  test "a long string stops at the node cap" do
    written = String.duplicate("y", (10_000 - 1) * 64)
    long = String.duplicate("y", 1_048_576)
    assert shown_quickly(long) == "\"#{written}\" ++ …"

    html = shown_quickly(element("p", [], [text(long)]))
    assert html == "<p>\n  {\"#{binary_part(written, 64, byte_size(written) - 64)}\" ++ …}\n</p>"

    fits = String.duplicate("y", 1000)
    assert shown_quickly([fits, 1]) == "[\"#{fits}\", 1]"
  end

  test "tags and attribute names count as strings" do
    long = String.duplicate("t", 1_048_576)
    el = fn tag, attr -> element(tag, [{"class", "c"}, {attr, 1}], [text("x")]) end

    assert shown_quickly([el.(long, "n"), el.("p", "n")]) ==
             ~S(<p class="c" n={1}>x</p>) |> then(&"[…, #{&1}]")

    assert shown_quickly(el.("p", long)) == ~S(<p class="c" …={…}>x</p>)
  end

  test "no attribute past the node cap is looked at" do
    attrs = List.duplicate({"a", "x"}, 20_000) ++ [0]
    shown = shown_quickly(element("p", attrs, []))
    assert String.starts_with?(shown, ~S(<p a="x" a="x"))
    assert String.ends_with?(shown, " …={…} />")
  end

  test "a big map is shown in Yabu key order, Int and String keys sorted natively" do
    ints = Map.new(Enum.shuffle(-100_000..100_000), &{&1, &1})
    assert String.starts_with?(shown_quickly(ints), "%{-100000 => -100000, -99999 => -99999,")

    strings = Map.new(1..200_000, &{"k#{&1}", 0}) |> Map.put("B", 1) |> Map.put("a", 2)

    assert String.starts_with?(
             shown_quickly(strings),
             ~s(%{"B" => 1, "a" => 2, "k1" => 0, "k10" => 0,)
           )

    # Other keys keep Yabu's order (Int before String, for a mixed map Exec never builds).
    assert Show.show(%{"a" => 1, 2 => 2, {1, 2} => 3}) == ~s[%{2 => 2, "a" => 1, (1, 2) => 3}]
  end

  test "a wide value stops at the node cap" do
    shown = shown_quickly(Enum.to_list(0..999_999))
    assert shown == "[" <> Enum.map_join(0..(10_000 - 2), ", ", &Integer.to_string/1) <> ", …]"

    # Text children in a row alternate between text and a string (Rust
    # writes each as text, which would read back as one run).
    html = shown_quickly(element("ul", [], List.duplicate(text("x"), 1_000_000)))
    plain = length(String.split(html, "\n  x")) - 1
    quoted = length(String.split(html, "\n  {\"x\"}")) - 1
    assert {plain, quoted} == {5_000, 4_999}
    assert String.ends_with?(html, "\n  {…}\n</ul>")
  end

  describe "round trips" do
    # Every value of the golden calls that source can write (no function,
    # no Uuid) evaluates back to itself from what `show` writes.
    test "eval(show(v)) is v for the corpus's and generated programs' values" do
      programs =
        Enum.map(YabuGolden.corpus(), &{YabuOracle.corpus_source(&1["file"]), &1["calls"]}) ++
          Enum.map(YabuGolden.generated(), &{&1["source"], &1["calls"]})

      checked =
        for {source, calls} <- programs, reduce: 0 do
          n ->
            u = universe(source)
            sigs = YabuGolden.signatures(source)

            values =
              for %{"name" => name, "args" => args} = call <- calls,
                  {params, ret} = YabuGolden.def_signature(sigs, name),
                  {json, type} <-
                    Enum.zip(args, params) ++ answer(call["answer"], ret),
                  {:ok, v} = YabuGolden.decode(json, type, sigs),
                  writable?(v),
                  do: {v, type}

            for {v, type} <- Enum.uniq(values) do
              shown = Exec.show(v, type)
              assert {:ok, back, _} = Exec.eval(u, shown), shown
              assert back == v, shown
            end

            n + length(values)
        end

      assert checked > 500
    end

    test "values only Exec builds round-trip too" do
      u = universe("deftype M.Msg do Go | Set(String) end\ndefmodel M.P do x : Int end")

      for v <- [
            {:cmd, {:batch, [:none, {:batch, [:none]}]}},
            %{[1, 2] => {true, "a"}, [] => {false, "\u{1F44B}\t"}},
            {:rec, "M.P", %{"x" => -9_223_372_036_854_775_807}},
            element("p", [{"on-click", var("M.Msg", "Go")}, {"class", "a b"}], [
              text("hi there"),
              text("a<b"),
              text(" pad "),
              element("i", [], [])
            ])
          ] do
        shown = Exec.show(v, nil)
        assert {:ok, ^v, _} = Exec.eval(u, shown), shown
      end
    end
  end

  defp answer(%{"value" => v}, ret), do: [{v, ret}]
  defp answer(_, _), do: []

  defp writable?(v) when is_function(v), do: false
  defp writable?({:uuid, _}), do: false
  defp writable?({:fn, _}), do: false
  defp writable?({:def_ref, _}), do: false
  defp writable?({:ctor_ref, _, _, _}), do: false
  defp writable?(l) when is_list(l), do: Enum.all?(l, &writable?/1)

  defp writable?(m) when is_map(m),
    do: Enum.all?(m, fn {k, v} -> writable?(k) and writable?(v) end)

  defp writable?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.all?(&writable?/1)
  defp writable?(_), do: true
end
