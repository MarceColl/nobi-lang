defmodule NobiGoldenTest do
  use ExUnit.Case, async: true

  @split File.read!("test/fixtures/nobi/split.nobi")
  @id "11111111-1111-4111-a111-111111111111"

  defp named(n), do: {:named, n}

  test "fixture counts" do
    assert length(NobiGolden.corpus()) == 4
    assert length(NobiGolden.generated()) == 300
    assert length(NobiGolden.stdlib()) > 0

    assert Enum.sum(for f <- NobiGolden.corpus(), do: length(f["calls"])) > 0
    assert Enum.sum(for f <- NobiGolden.corpus(), do: map_size(f["tests"])) == 3
    assert Enum.sum(for p <- NobiGolden.generated(), do: length(p["calls"])) > 0
    assert Enum.sum(for p <- NobiGolden.generated(), do: length(p["traces"])) > 0
  end

  test "the corpus files are the ones piece 1 migrated" do
    assert Enum.map(NobiGolden.corpus(), & &1["file"]) ==
             Enum.map(NobiOracle.corpus(), & &1["file"])
  end

  test "generated sources are byte-identical to piece 1's typed-Html sources" do
    assert Enum.map(NobiGolden.generated(), &{&1["seed"], &1["source"]}) ==
             Enum.map(NobiOracle.generated(), &{&1["seed"], &1["source"]})
  end

  test "every generated and corpus answer decodes by its declared types" do
    check = fn source, calls ->
      sigs = NobiGolden.signatures(source)

      for %{"name" => name, "args" => args, "answer" => answer} <- calls do
        {params, ret} = NobiGolden.def_signature(sigs, name)

        for {a, t} <- Enum.zip(args, params),
            do: assert({:ok, _} = NobiGolden.decode(a, t, sigs), "#{name} arg")

        with %{"value" => v} <- answer,
             do: assert({:ok, _} = NobiGolden.decode(v, ret, sigs), "#{name} result")
      end
    end

    for p <- NobiGolden.generated(), do: check.(p["source"], p["calls"])
    for f <- NobiGolden.corpus(), do: check.(NobiOracle.corpus_source(f["file"]), f["calls"])
  end

  test "the decoder reads a value by its declared type" do
    sigs = NobiGolden.signatures(@split)
    msg = named("Split.Msg")

    assert {:ok, {:var, "Split.Msg", "Added", [{:uuid, @id}]}} =
             NobiGolden.decode(%{"$v" => "Split.Msg.Added", "a" => [@id]}, msg, sigs)

    assert {:ok, {:var, "Split.Msg", "SetPayer", [@id]}} =
             NobiGolden.decode(%{"$v" => "Split.Msg.SetPayer", "a" => [@id]}, msg, sigs)

    callback = {:arrow, [named("String")], msg}

    assert {:ok, {:ctor_ref, "Split.Msg", "SetPayer", 1}} =
             NobiGolden.decode(%{"$fn" => "Split.Msg.SetPayer"}, callback, sigs)

    money = {:arrow, [named("Int")], named("String")}

    assert {:ok, {:def_ref, "Split.money"}} =
             NobiGolden.decode(%{"$fn" => "Split.money"}, money, sigs)

    assert {:ok, NobiGolden.lambda()} ==
             NobiGolden.decode(%{"$fn" => "<lambda>"}, callback, sigs)

    assert {:error, _} = NobiGolden.decode(@id, named("Int"), sigs)
    assert {:error, _} = NobiGolden.decode("NOT-A-UUID", named("Uuid"), sigs)
  end

  test "records, maps, tuples, Option, Html and Cmd decode to the spec's shapes" do
    sigs = NobiGolden.signatures(@split)

    assert {:ok, {:rec, "Split.Share", %{"who" => "a", "owes" => 1}}} =
             NobiGolden.decode(
               %{"$t" => "Split.Share", "who" => "a", "owes" => 1},
               named("Split.Share"),
               sigs
             )

    map = %{"$map" => [["a", 1], ["a", 2], ["b", 3]]}

    assert {:ok, %{"a" => 2, "b" => 3}} =
             NobiGolden.decode(map, {:applied, "Map", [named("String"), named("Int")]}, sigs)

    assert {:ok, {1, "x"}} =
             NobiGolden.decode(
               %{"$tup" => [1, "x"]},
               {:tuple, [named("Int"), named("String")]},
               sigs
             )

    some = %{"$v" => "Option.Some", "a" => [3]}

    assert {:ok, {:var, "Option", "Some", [3]}} =
             NobiGolden.decode(some, {:applied, "Option", [named("Int")]}, sigs)

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
             ]}} = NobiGolden.decode(html, {:applied, "Html", [msg_t()]}, sigs)

    cmd_t = {:applied, "Cmd", [msg_t()]}
    assert {:ok, {:cmd, :none}} = NobiGolden.decode(%{"$c" => "none"}, cmd_t, sigs)

    list = %{"$c" => "store.list", "model" => "Split.Expense", "cb" => %{"$fn" => "<lambda>"}}

    assert {:ok, {:cmd, {:effect, "Cmd.store.list", "Split.Expense", [{:fn, "<lambda>"}]}}} =
             NobiGolden.decode(list, cmd_t, sigs)

    batch = %{"$c" => "batch", "cmds" => [%{"$c" => "none"}]}
    assert {:ok, {:cmd, {:batch, [:none]}}} = NobiGolden.decode(batch, cmd_t, sigs)
  end

  test "without_closures writes every fun as the marker" do
    f = fn -> 1 end

    assert NobiGolden.without_closures({:cmd, {:effect, "Cmd.x", nil, [f, [f, 1]]}}) ==
             {:cmd, {:effect, "Cmd.x", nil, [NobiGolden.lambda(), [NobiGolden.lambda(), 1]]}}

    assert NobiGolden.without_closures(%{"k" => f}) == %{"k" => NobiGolden.lambda()}
  end

  test "without_closures keeps a def or a constructor, as its marker" do
    ctor = Nobi.Lang.Rt.ctor("Split.Msg", "SetPayer", 1)
    assert NobiGolden.without_closures([ctor]) == [{:ctor_ref, "Split.Msg", "SetPayer", 1}]

    length = &Nobi.Lang.Rt.Stdlib.string_length/1
    assert NobiGolden.without_closures({length}) == {{:def_ref, "String.length"}}
  end

  defp msg_t, do: named("Split.Msg")
end
