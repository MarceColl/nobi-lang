defmodule Nobi.Lang.KeysTest do
  @moduledoc """
  The map-key rule's settling (`Nobi.Lang.Types.Keys`) against a
  reference that works every deftype out again, round after round, until
  none changes (the Rust crate's `keys.rs` property test, here over seeded
  random tables).
  """
  use ExUnit.Case, async: true

  alias Nobi.Lang.Types.{Extract, Keys, Stdlib}

  @applied ~w(T.A T.B T.C T.D T.Model T.Missing Map List Option)
  @deftypes ~w(T.A T.B T.C T.D)

  defp builtin?(name), do: Map.has_key?(Extract.builtin_applied(), name)

  # ---------- the reference ----------

  defp reaching_by_rounds(sigs) do
    deftypes = for {n, {:type, ps, vs}} <- sigs, not builtin?(n), do: {n, ps, vs}
    start = Map.new(deftypes, fn {n, ps, _} -> {n, Enum.map(ps, fn _ -> false end)} end)
    rounds(deftypes, start)
  end

  defp rounds(deftypes, reaching) do
    next =
      Map.new(deftypes, fn {n, ps, vs} ->
        held =
          for {_, args} <- vs,
              a <- args,
              reduce: MapSet.new(),
              do: (acc -> in_keys(a, reaching, acc))

        {n, Enum.map(ps, &MapSet.member?(held, &1))}
      end)

    if next == reaching, do: reaching, else: rounds(deftypes, next)
  end

  # Each name `t` holds where a key would hold it.
  defp in_keys({:applied, name, args}, reaching, out) do
    out = if name == "Map", do: args |> Enum.take(1) |> Enum.reduce(out, &names/2), else: out

    out =
      case reaching do
        %{^name => r} when length(r) == length(args) ->
          for {a, true} <- Enum.zip(args, r), reduce: out, do: (acc -> names(a, acc))

        _ ->
          out
      end

    Enum.reduce(args, out, &in_keys(&1, reaching, &2))
  end

  defp in_keys({:arrow, ps, r}, reaching, out),
    do: Enum.reduce([r | ps], out, &in_keys(&1, reaching, &2))

  defp in_keys({:tuple, items}, reaching, out),
    do: Enum.reduce(items, out, &in_keys(&1, reaching, &2))

  defp in_keys(_, _, out), do: out

  # Every name in `t`.
  defp names({:named, n}, out), do: MapSet.put(out, n)
  defp names({:var, n}, out), do: MapSet.put(out, n)
  defp names({:applied, _, args}, out), do: Enum.reduce(args, out, &names/2)
  defp names({:tuple, items}, out), do: Enum.reduce(items, out, &names/2)
  defp names({:arrow, ps, r}, out), do: Enum.reduce([r | ps], out, &names/2)

  # What `name`'s variants apply, builtins aside: nothing for a name that is
  # no deftype.
  defp applies_of(sigs, name) do
    case sigs[name] do
      {:type, _, vs} ->
        for {_, args} <- vs,
            a <- args,
            n <- applied(a),
            not builtin?(n),
            into: MapSet.new(),
            do: n

      _ ->
        MapSet.new()
    end
  end

  defp applied({:applied, n, args}), do: [n | Enum.flat_map(args, &applied/1)]
  defp applied({:arrow, ps, r}), do: Enum.flat_map([r | ps], &applied/1)
  defp applied({:tuple, items}), do: Enum.flat_map(items, &applied/1)
  defp applied(_), do: []

  defp closure(_sigs, [], seen), do: seen

  defp closure(sigs, [n | todo], seen) do
    if MapSet.member?(seen, n),
      do: closure(sigs, todo, seen),
      else: closure(sigs, MapSet.to_list(applies_of(sigs, n)) ++ todo, MapSet.put(seen, n))
  end

  # ---------- random tables ----------

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)
  defp between(lo, hi), do: lo + :rand.uniform(hi - lo + 1) - 1

  defp arg(depth) do
    if depth < 4 and :rand.uniform(2) == 1 do
      case :rand.uniform(6) do
        n when n <= 4 ->
          {:applied, pick(@applied), for(_ <- 1..between(1, 2), do: arg(depth + 1))}

        5 ->
          {:tuple, for(_ <- 1..between(2, 3), do: arg(depth + 1))}

        6 ->
          {:arrow, for(_ <- 1..between(0, 2)//1, do: arg(depth + 1)), arg(depth + 1)}
      end
    else
      if :rand.uniform(5) <= 4, do: {:named, pick(~w(K V W Int))}, else: {:var, pick(~w(K a))}
    end
  end

  defp table do
    types =
      Map.new(@deftypes, fn name ->
        params = for _ <- 1..between(1, 2), do: pick(~w(K V W))

        variants =
          for i <- 0..between(-1, 2)//1,
              i >= 0,
              do: {"V#{i}", for(_ <- 1..between(0, 2)//1, do: arg(0))}

        {name, {:type, params, variants}}
      end)

    Map.merge(types, %{"Option" => Stdlib.signatures()["Option"], "T.Model" => {:model, []}})
  end

  test "settling agrees with working everything out round after round" do
    :rand.seed(:exsss, {8, 13, 21})

    for _ <- 1..500 do
      sigs = table()
      reference = reaching_by_rounds(sigs)
      roots = Enum.shuffle(Enum.reject(@applied, &builtin?/1))

      # Settled one root at a time, in any order, each settle using what the
      # ones before it settled.
      Enum.reduce(roots, Keys.new(), fn root, memo ->
        {reach, memo} = Keys.reach(memo, root, sigs)
        assert reach.reaching == Map.get(reference, root, []), "#{root}: #{inspect(sigs)}"
        assert reach.names == closure(sigs, [root], MapSet.new()), "#{root}: #{inspect(sigs)}"
        memo
      end)

      # A group settled on its own reads every name it takes in, and no other.
      for root <- roots do
        me = self()
        lookup = fn name -> send(me, {:read, name}) && sigs[name] end
        group = Keys.reaching(root, lookup)
        assert group == Keys.settle(root, sigs).names
        assert read_names(MapSet.new()) == group, "#{root}: #{inspect(sigs)}"
      end
    end
  end

  defp read_names(acc) do
    receive do
      {:read, name} -> read_names(MapSet.put(acc, name))
    after
      0 -> acc
    end
  end

  test "reaching is the group a map-key check depends on" do
    sigs = %{
      "M.Inner" => {:type, ["K"], [{"I", [{:named, "K"}]}]},
      "M.W" => {:type, ["K"], [{"W", [{:applied, "M.Inner", [{:named, "K"}]}]}]},
      "M.Lone" => {:type, ["K"], [{"L", [{:applied, "List", [{:named, "K"}]}]}]}
    }

    assert Keys.reaching("M.W", sigs) == MapSet.new(["M.W", "M.Inner"])
    assert Keys.reaching("M.Lone", sigs) == MapSet.new(["M.Lone"])
    assert Keys.reaching("M.Nowhere", sigs) == MapSet.new(["M.Nowhere"])
    assert Keys.settle("M.W", sigs).reaching == [false]
  end
end
