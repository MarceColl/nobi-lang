defmodule YabuGoldenTest do
  use ExUnit.Case, async: true

  @split File.read!("test/fixtures/yabu/split.yabu")
  @id "11111111-1111-4111-a111-111111111111"

  defp named(n), do: {:named, n}

  test "fixture counts" do
    assert length(YabuGolden.corpus()) == 4
    assert length(YabuGolden.generated()) == 300
    assert length(YabuGolden.stdlib()) > 0

    assert Enum.sum(for f <- YabuGolden.corpus(), do: length(f["calls"])) > 0
    assert Enum.sum(for f <- YabuGolden.corpus(), do: map_size(f["tests"])) == 3
    assert Enum.sum(for p <- YabuGolden.generated(), do: length(p["calls"])) > 0
    assert Enum.sum(for p <- YabuGolden.generated(), do: length(p["traces"])) > 0
  end

  test "the corpus files are the ones piece 1 migrated" do
    assert Enum.map(YabuGolden.corpus(), & &1["file"]) ==
             Enum.map(YabuOracle.corpus(), & &1["file"])
  end

  test "generated sources are byte-identical to piece 1's typed-Html sources" do
    assert Enum.map(YabuGolden.generated(), &{&1["seed"], &1["source"]}) ==
             Enum.map(YabuOracle.generated(), &{&1["seed"], &1["source"]})
  end

  test "every generated and corpus answer decodes by its declared types" do
    check = fn source, calls ->
      sigs = YabuGolden.signatures(source)

      for %{"name" => name, "args" => args, "answer" => answer} <- calls do
        {params, ret} = YabuGolden.def_signature(sigs, name)

        for {a, t} <- Enum.zip(args, params),
            do: assert({:ok, _} = YabuGolden.decode(a, t, sigs), "#{name} arg")

        with %{"value" => v} <- answer,
             do: assert({:ok, _} = YabuGolden.decode(v, ret, sigs), "#{name} result")
      end
    end

    for p <- YabuGolden.generated(), do: check.(p["source"], p["calls"])
    for f <- YabuGolden.corpus(), do: check.(YabuOracle.corpus_source(f["file"]), f["calls"])
  end

  test "the decoder reads a value by its declared type" do
    sigs = YabuGolden.signatures(@split)
    msg = named("Split.Msg")

    assert {:ok, {:var, "Split.Msg", "Added", [{:uuid, @id}]}} =
             YabuGolden.decode(%{"$v" => "Split.Msg.Added", "a" => [@id]}, msg, sigs)

    assert {:ok, {:var, "Split.Msg", "SetPayer", [@id]}} =
             YabuGolden.decode(%{"$v" => "Split.Msg.SetPayer", "a" => [@id]}, msg, sigs)

    callback = {:arrow, [named("String")], msg}

    assert {:ok, {:ctor_ref, "Split.Msg", "SetPayer", 1}} =
             YabuGolden.decode(%{"$fn" => "Split.Msg.SetPayer"}, callback, sigs)

    money = {:arrow, [named("Int")], named("String")}

    assert {:ok, {:def_ref, "Split.money"}} =
             YabuGolden.decode(%{"$fn" => "Split.money"}, money, sigs)

    assert {:ok, YabuGolden.lambda()} ==
             YabuGolden.decode(%{"$fn" => "<lambda>"}, callback, sigs)

    assert {:error, _} = YabuGolden.decode(@id, named("Int"), sigs)
    assert {:error, _} = YabuGolden.decode("NOT-A-UUID", named("Uuid"), sigs)
  end

  test "records, maps, tuples, Option, Html and Cmd decode to the spec's shapes" do
    sigs = YabuGolden.signatures(@split)

    assert {:ok, {:rec, "Split.Share", %{"who" => "a", "owes" => 1}}} =
             YabuGolden.decode(
               %{"$t" => "Split.Share", "who" => "a", "owes" => 1},
               named("Split.Share"),
               sigs
             )

    map = %{"$map" => [["a", 1], ["a", 2], ["b", 3]]}

    assert {:ok, %{"a" => 2, "b" => 3}} =
             YabuGolden.decode(map, {:applied, "Map", [named("String"), named("Int")]}, sigs)

    assert {:ok, {1, "x"}} =
             YabuGolden.decode(
               %{"$tup" => [1, "x"]},
               {:tuple, [named("Int"), named("String")]},
               sigs
             )

    some = %{"$v" => "Option.Some", "a" => [3]}

    assert {:ok, {:var, "Option", "Some", [3]}} =
             YabuGolden.decode(some, {:applied, "Option", [named("Int")]}, sigs)

    html = %{
      "$h" => "div",
      "at" => [["class", "x"], ["on-click", %{"$v" => "Split.Msg.Added", "a" => [@id]}]],
      "ch" => ["t", 4, true, [%{"$h" => "b", "at" => [], "ch" => []}]]
    }

    assert {:ok,
            {:var, "Html", "Element",
             [
               "div",
               [{"class", "x"}, {"on-click", {:var, "Split.Msg", "Added", [{:uuid, @id}]}}],
               [
                 {:var, "Html", "Text", ["t"]},
                 {:var, "Html", "Text", ["4"]},
                 {:var, "Html", "Text", ["true"]},
                 {:var, "Html", "Element", ["b", [], []]}
               ]
             ]}} = YabuGolden.decode(html, {:applied, "Html", [msg_t()]}, sigs)

    cmd_t = {:applied, "Cmd", [msg_t()]}
    assert {:ok, {:cmd, :none}} = YabuGolden.decode(%{"$c" => "none"}, cmd_t, sigs)

    list = %{"$c" => "store.list", "model" => "Split.Expense", "cb" => %{"$fn" => "<lambda>"}}

    assert {:ok, {:cmd, {:effect, "Cmd.store.list", "Split.Expense", [{:fn, "<lambda>"}]}}} =
             YabuGolden.decode(list, cmd_t, sigs)

    batch = %{"$c" => "batch", "cmds" => [%{"$c" => "none"}]}
    assert {:ok, {:cmd, {:batch, [:none]}}} = YabuGolden.decode(batch, cmd_t, sigs)
  end

  test "without_closures writes every fun as the marker" do
    f = fn -> 1 end

    assert YabuGolden.without_closures({:cmd, {:effect, "Cmd.x", nil, [f, [f, 1]]}}) ==
             {:cmd, {:effect, "Cmd.x", nil, [YabuGolden.lambda(), [YabuGolden.lambda(), 1]]}}

    assert YabuGolden.without_closures(%{"k" => f}) == %{"k" => YabuGolden.lambda()}
  end

  test "without_closures keeps a def or a constructor, as its marker" do
    ctor = Kinoko.Lang.Rt.ctor("Split.Msg", "SetPayer", 1)
    assert YabuGolden.without_closures([ctor]) == [{:ctor_ref, "Split.Msg", "SetPayer", 1}]

    length = &Kinoko.Lang.Rt.Stdlib.string_length/1
    assert YabuGolden.without_closures({length}) == {{:def_ref, "String.length"}}
  end

  defp msg_t, do: named("Split.Msg")
end
