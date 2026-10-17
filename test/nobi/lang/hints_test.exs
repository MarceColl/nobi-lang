defmodule Nobi.Lang.HintsTest do
  @moduledoc """
  What an unbound name says (`Nobi.Lang.Types.Hints`), against a scan of
  the whole table: the Rust crate's `hints.rs` unit test. The name index and
  the per-check cache must give word for word what a scan gives.
  """
  use ExUnit.Case, async: true

  alias Nobi.Lang.Types.{Check, Extract, Hints, Stdlib}
  alias Nobi.Lang.Types.Check.Ctx

  # What an unbound name said when every message scanned the whole table.
  defp by_scan(sigs, local, name, as_value) do
    dotted = String.contains?(name, ".")
    owner = Extract.owner_of(name)
    lower = String.downcase(name)

    close = fn q ->
      String.downcase(q) == lower or
        (not dotted and String.downcase(Extract.last_segment(q)) == lower)
    end

    found =
      cond do
        Map.has_key?(sigs, name) ->
          name

        dotted and Map.has_key?(sigs, owner) ->
          owner

        true ->
          Enum.find(Stdlib.names(), &(close.(&1) and Map.has_key?(sigs, &1))) ||
            sigs
            |> Map.keys()
            |> Enum.sort()
            |> Enum.find(&(not Map.has_key?(Stdlib.signatures(), &1) and close.(&1)))
      end

    near =
      if dotted,
        do:
          sigs
          |> Map.keys()
          |> Enum.filter(&(String.starts_with?(&1, owner <> ".") and &1 != name))
          |> Enum.sort(),
        else: []

    cond do
      found == name ->
        Hints.misuse_hint(found, sigs[found])

      found != nil ->
        "`#{name}` is not in scope — #{Hints.misuse_hint(found, sigs[found])}"

      near != [] ->
        shown = near |> Enum.take(8) |> Enum.map_join(", ", &"`#{&1}`")
        more = if length(near) > 8, do: ", …", else: ""
        "there is no `#{name}` — `#{owner}` has #{shown}#{more}"

      as_value and match?([^local, _], String.split(name, ".", parts: 2)) ->
        [root, rest] = String.split(name, ".", parts: 2)

        "`#{name}` is not in scope — `#{root}` is a local, but `#{name}` reads as one dotted name, not a field of " <>
          "it: write `(#{root}).#{rest}`"

      true ->
        "unbound symbol `#{name}`"
    end
  end

  # The stdlib, and a program whose names collide with it and with one
  # another but for case, whole and by their last segment; that overrides a
  # stdlib name; and whose namespaces hold eight, nine and twelve names.
  defp mixed_table do
    def_ = {:def, [], {:named, "Int"}, []}

    defs =
      ~w(App.length Shop.item A.thing A.shop B.Thing C.THING List.map Cmd.Store.GET Ünï.cödé)
      |> Map.new(&{&1, def_})

    counted =
      for {owner, count} <- [{"Eight", 8}, {"Nine", 9}, {"Big", 12}],
          i <- 0..(count - 1),
          into: %{} do
        {"#{owner}.f#{i}", def_}
      end

    Stdlib.signatures()
    |> Map.merge(defs)
    |> Map.merge(counted)
    |> Map.merge(%{
      "Shop.Item" => {:model, [{"name", {:named, "String"}, :none}]},
      "Shop.Size" => {:type, [], [{"Small", []}, {"Large", []}]},
      "Shop.Empty" => {:type, [], []},
      "Shop" => :app,
      "Shop.it_works" => :test
    })
  end

  defp guesses(sigs) do
    fixed = ["nowhere", "Nowhere.at_all", "m.x", "Thing", "THING", "get", "GET", "ünï.CÖDÉ"]

    fixed ++
      Enum.flat_map(Map.keys(sigs), fn name ->
        last = Extract.last_segment(name)
        owner = Extract.owner_of(name)

        [
          name,
          String.downcase(name),
          String.upcase(name),
          last,
          String.downcase(last),
          String.upcase(last),
          owner,
          "#{owner}.missing",
          "#{owner}.Missing",
          "Zz.#{last}"
        ]
      end)
  end

  test "every unbound message reads as a scan of the table wrote it" do
    sigs = mixed_table()
    ctx = Ctx.new(sigs) |> Ctx.push_scope(%{"m" => {:named, "Int"}})

    {said, _ctx} =
      for name <- guesses(sigs), as_value <- [true, false], reduce: {[], ctx} do
        {said, ctx} ->
          {message, ctx} = Check.unbound_message(ctx, name, as_value)
          assert message == by_scan(sigs, "m", name, as_value), "#{name} #{as_value}"
          {[message | said], ctx}
      end

    for kind <- [
          " is not in scope — `",
          " is what you want",
          " is a model",
          " is a type, not a value — ",
          " has no variants",
          " is an app",
          " is a test",
          ", …",
          "` has `",
          "` is a local",
          "unbound symbol"
        ] do
      assert Enum.any?(said, &String.contains?(&1, kind)), "no message says #{inspect(kind)}"
    end

    for {guess, first} <- [
          {"get", "Cmd.store.get"},
          {"Thing", "A.thing"},
          {"ünï.CÖDÉ", "Ünï.cödé"}
        ] do
      {message, _} = Check.unbound_message(ctx, guess, true)
      assert String.starts_with?(message, "`#{guess}` is not in scope — `#{first}`"), message
    end
  end

  test "a diagnostic peek records nothing" do
    ctx = Ctx.new(mixed_table())
    {_, after_peek} = Check.unbound_message(ctx, "board", true)
    assert after_peek.used == MapSet.new()
  end

  # A lookup check (the universe's database) words each unbound name with
  # no table; `reword/2` gives it what a check against the table says.
  test "a lookup check's unbound messages reworded match a table check's" do
    sigs = mixed_table()
    table = Hints.table(sigs)
    ctx = Ctx.new(&Map.get(sigs, &1)) |> Ctx.push_scope(%{"m" => {:named, "Int"}})

    for name <- guesses(sigs), as_value <- [true, false] do
      {raw, _} = Check.unbound_message(ctx, name, as_value)
      reworded = Hints.reword(table, %{unbound: name, message: raw})
      assert reworded == by_scan(sigs, "m", name, as_value), "#{name} #{as_value}"
    end

    assert Hints.reword(table, %{unbound: nil, message: "kept"}) == "kept"
  end

  # A table handed in is the one a check words its messages from: a caller
  # checking many declarations against one table builds it once.
  test "a check uses the table it is handed, never building its own" do
    sigs = Stdlib.signatures()

    decl =
      {:def, [], ["A.f", [], {:named, "Int"}, {:block, [], [[], {:call, [], ["A.thing", []]}]}]}

    other = Hints.table(Map.put(sigs, "A.Thing", {:model, []}))

    assert {:error, [%{message: "unbound symbol `A.thing`"}]} = Check.decl(decl, sigs).result

    assert {:error, [%{message: "`A.thing` is not in scope — `A.Thing` is a model" <> _}]} =
             Check.decl(decl, sigs, table: other).result

    assert Check.decl(decl, sigs, table: Hints.table(sigs)) == Check.decl(decl, sigs)
  end
end
