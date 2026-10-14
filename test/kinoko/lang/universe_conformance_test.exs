defmodule Kinoko.Lang.UniverseConformanceTest do
  @moduledoc """
  The Elixir universe against the Quint universe specs (a port of the Rust
  `tests/universe_conformance.rs`). Quint generates traces; each spec patch is
  turned into Yabu with the same typing (a declaration's `sig` is its return
  type, each `uses` entry is a call that must return that type, and `Gone` is a
  tombstone) and replayed here.

  - `abstract.qnt`: every step is a patch that either promoted or was refused
    with the names it would break. It is staged under one id and must get the
    same verdict and leave the same committed code.
  - `universe.qnt`: every step stages a patch under an id or unstages one, and
    must leave the same committed code, staged patches with the same reasons,
    the same history, and the same kind of step.

  Excluded by default (about 80 s, needs `quint` on PATH). Run it with
  `mix test --include quint test/kinoko/lang/universe_conformance_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Kinoko.Lang.{Format, Parser, Universe}

  @moduletag :quint
  @moduletag timeout: 1_800_000

  # --- ITF decoding ---------------------------------------------------------

  defp int(%{"#bigint" => s}), do: String.to_integer(s)
  defp map(%{"#map" => kvs}), do: kvs
  defp set(%{"#set" => xs}), do: xs

  defp ty(1), do: "Int"
  defp ty(_), do: "String"
  defp lit(1), do: "0"
  defp lit(_), do: "\"\""

  # The Yabu definition whose typing is exactly the spec declaration's.
  defp source(name, decl) do
    sig = int(decl["sig"])

    uses =
      for [n, s] <- map(decl["uses"]), do: "M.#{n}() == #{lit(int(s))}"

    body =
      case uses do
        [] -> lit(sig)
        _ -> "if #{Enum.join(uses, " and ")} do #{lit(sig)} else #{lit(sig)} end"
      end

    "def M.#{name}() : #{ty(sig)} do #{body} end"
  end

  defp parse!(src) do
    {:ok, [decl]} = Parser.program(src)
    decl
  end

  defp formatted(src), do: src |> parse!() |> Format.decl()

  # A spec patch (`Name -> Entry`) as a Yabu one.
  defp patch(p) do
    for [name, entry] <- map(p) do
      case entry["tag"] do
        "Live" -> {:live, parse!(source(name, entry["value"]))}
        "Gone" -> {:gone, "M.#{name}"}
        tag -> flunk("an entry is Live or Gone, not #{tag}")
      end
    end
  end

  # A patch's entries by name: each declaration formatted, a tombstone nil.
  defp spec_entries(p) do
    for([name, entry] <- map(p), do: spec_entry(name, entry)) |> Enum.sort()
  end

  defp spec_entry(name, %{"tag" => "Live", "value" => v}),
    do: {"M.#{name}", formatted(source(name, v))}

  defp spec_entry(name, _), do: {"M.#{name}", nil}

  defp ex_entries(p) do
    p
    |> Enum.map(fn
      {:live, decl} -> {Kinoko.Lang.Ast.name(decl), Format.decl(decl)}
      {:gone, name} -> {name, nil}
    end)
    |> Enum.sort()
  end

  # A history round's entries, each CID read back from the universe's texts.
  defp round_entries(u, round) do
    round.entries
    |> Enum.map(fn
      {:live, name, cid} -> {name, Universe.text(u, cid)}
      {:gone, name} -> {name, nil}
    end)
    |> Enum.sort()
  end

  # The spec variable whose name ends in `::<name>`.
  defp var(state, name) do
    {_, v} = Enum.find(state, fn {k, _} -> String.ends_with?(k, "::" <> name) end)
    v
  end

  defp spec_committed(state) do
    for [n, decl] <- map(var(state, "committed")), do: {"M.#{n}", formatted(source(n, decl))}
  end

  defp ex_committed(u) do
    for {n, c} <- Universe.committed(u), do: {n, Format.decl(c.decl)}
  end

  # The names `reasons` refuse a patch for. The universe gives one reason per
  # error; Rust joins a declaration's errors into one reason, so a name
  # counts once.
  defp refused(reasons), do: reasons |> Enum.map(& &1.name) |> Enum.dedup()

  # --- running quint --------------------------------------------------------

  defp specs_dir do
    System.get_env("KINOKO_NEXT_SPECS") || Path.expand("~/proj/kinoko-next/specs")
  end

  defp traces(label, spec, args) do
    out =
      Path.join(
        System.tmp_dir!(),
        "kinoko-itf-#{label}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(out)

    try do
      {output, status} =
        System.cmd(
          System.find_executable("quint"),
          ["run", Path.join(specs_dir(), spec)] ++
            args ++ ["--out-itf", Path.join(out, "trace_{seq}.itf.json")],
          cd: Path.dirname(specs_dir()),
          stderr_to_stdout: true
        )

      assert status == 0, "quint run failed:\n#{output}"

      all =
        out
        |> File.ls!()
        |> Enum.sort()
        |> Enum.map(&(out |> Path.join(&1) |> File.read!() |> JSON.decode!()))

      all
    after
      File.rm_rf!(out)
    end
  end

  # --- abstract -------------------------------------------------------------

  test "the universe follows every abstract trace" do
    args =
      ~w(--main universe_abstract_live --step stepLive --max-steps 10 --max-samples 1000 --n-traces 1000 --mbt --seed 7)

    traces = traces("abstract", "universe/abstract.qnt", args)
    assert length(traces) >= 500, "quint produced only #{length(traces)} traces"

    {promotions, refusals} =
      Enum.reduce(traces, {0, 0}, fn trace, acc ->
        trace["states"]
        |> Enum.drop(1)
        |> Enum.with_index(1)
        |> Enum.reduce({Universe.new(), acc}, fn {state, i}, {u, {pro, ref}} ->
          p = state["mbt::nondetPicks"]["p"]["value"]
          {u, verdict} = Universe.stage(u, "patch", patch(p))

          got =
            case verdict do
              {:promoted, _} -> []
              {:staged, reasons} -> refused(reasons)
            end

          want = for n <- set(var(state, "reasons")), do: "M.#{n}"

          assert got == want,
                 "step #{i}: the names refused: got #{inspect(got)} want #{inspect(want)}\n#{inspect(p)}"

          assert Enum.sort(ex_committed(u)) == Enum.sort(spec_committed(state)),
                 "step #{i}: committed code"

          {u, if(want == [], do: {pro + 1, ref}, else: {pro, ref + 1})}
        end)
        |> elem(1)
      end)

    IO.puts("checked #{promotions} promotions and #{refusals} refusals")

    assert promotions >= 300 and refusals >= 300,
           "only #{promotions} promotions and #{refusals} refusals were checked"
  end

  # --- concrete -------------------------------------------------------------

  test "the universe follows every concrete trace" do
    # 25 steps, not check.sh's 12: code builds up, so tombstones remove
    # committed names.
    args =
      ~w(--main universe_3 --max-steps 25 --max-samples 1000 --n-traces 1000 --mbt --seed 7)

    traces = traces("concrete", "universe/universe.qnt", args)
    assert length(traces) >= 500, "quint produced only #{length(traces)} traces"
    seen = replay_concrete(traces)

    assert seen["rounds"] >= 800 and seen["tombstones applied"] >= 100 and
             seen["names removed"] >= 10 and seen["cascade"] >= 60 and
             seen["unstage"] >= 3000,
           "too few of each kind of step were checked: #{inspect(seen)}"
  end

  test "the universe follows every concrete trace that removes what others use" do
    args =
      ~w(--main universe_3_removing --step stepRemoving --max-steps 25 --max-samples 1000 --n-traces 1000 --mbt --seed 7)

    traces = traces("removing", "universe/universe.qnt", args)
    assert length(traces) >= 500, "quint produced only #{length(traces)} traces"
    seen = replay_concrete(traces)

    assert seen["names removed"] >= 250 and seen["names removed in use"] >= 20 and
             seen["copies restaged"] >= 1500 and seen["copies promoted together"] >= 3,
           "too few of each kind of step were checked: #{inspect(seen)}"
  end

  defp spec_concrete(state) do
    reasons =
      Map.new(map(var(state, "reasons")), fn [id, ns] ->
        {int(id), for(n <- set(ns), do: "M.#{n}")}
      end)

    %{
      committed: spec_committed(state),
      staged:
        for [id, p] <- map(var(state, "staged")) do
          {Integer.to_string(int(id)), spec_entries(p), Map.fetch!(reasons, int(id))}
        end,
      history: Enum.map(var(state, "history"), &spec_entries/1),
      last_action: var(state, "lastAction")
    }
  end

  defp ex_concrete(u, last_action) do
    %{
      committed: ex_committed(u),
      staged:
        for {id, p} <- Universe.staged(u) do
          {id, ex_entries(p), refused(Universe.reasons(u, id))}
        end,
      history: Enum.map(Universe.history(u), &round_entries(u, &1)),
      last_action: last_action
    }
  end

  defp normalize(c) do
    %{c | committed: Enum.sort(c.committed), staged: Enum.sort(c.staged)}
  end

  defp kind(rounds) do
    if length(rounds) > 1 or Enum.any?(rounds, &(length(&1.ids) > 1)),
      do: "cascade",
      else: "stage"
  end

  defp bump(seen, key, n \\ 1), do: Map.update(seen, key, n, &(&1 + n))

  defp replay_concrete(traces) do
    Enum.reduce(traces, %{}, fn trace, seen ->
      states = trace["states"]

      states
      |> Enum.zip(tl(states))
      |> Enum.with_index(1)
      |> Enum.reduce({Universe.new(), seen}, fn {{prior, state}, i}, {u, seen} ->
        step(u, seen, prior, state, i)
      end)
      |> elem(1)
    end)
  end

  defp step(u, seen, prior, state, i) do
    picks = state["mbt::nondetPicks"]
    id = picks["id"]["value"] |> int() |> Integer.to_string()
    before = length(Universe.history(u))
    committed_before = Map.keys(Universe.committed(u))

    staged_before =
      Map.new(Universe.staged(u), fn {j, p} -> {j, ex_entries(p)} end)

    {u, action, seen} =
      case state["mbt::actionTaken"] do
        "stage" ->
          p = patch(picks["p"]["value"])
          entries = ex_entries(p)

          restaged =
            Enum.any?(staged_before, fn {j, q} -> j != id and q == entries end)

          seen = bump(seen, "copies restaged", if(restaged, do: 1, else: 0))
          staged_before = Map.put(staged_before, id, entries)
          {u, verdict} = Universe.stage(u, id, p)
          added = u |> Universe.history() |> Enum.drop(before)
          promoted = Enum.flat_map(added, & &1.ids)

          case verdict do
            {:promoted, ids} -> assert ids == promoted, "step #{i}: promoted ids"
            {:staged, reasons} -> assert reasons == Universe.reasons(u, id), "step #{i}: reasons"
          end

          left = u |> Universe.staged() |> Map.keys() |> MapSet.new()

          unstaged =
            staged_before |> Map.keys() |> Enum.reject(&MapSet.member?(left, &1)) |> MapSet.new()

          assert unstaged == MapSet.new(promoted), "step #{i}: what left staging"

          seen =
            Enum.reduce(added, seen, fn round, seen ->
              patches = round.ids |> Enum.map(&Map.fetch!(staged_before, &1)) |> MapSet.new()

              bump(
                seen,
                "copies promoted together",
                if(MapSet.size(patches) < length(round.ids), do: 1, else: 0)
              )
            end)

          {u, kind(added), seen}

        "unstage" ->
          {u, dropped} = Universe.unstage(u, id)
          assert dropped, "step #{i}: #{id} was staged"
          {u, "unstage", seen}

        action ->
          flunk("the spec has no action #{action}")
      end

    added = u |> Universe.history() |> Enum.drop(before)
    seen = seen |> bump(action) |> bump("rounds", length(added))

    tombstones =
      added |> Enum.flat_map(& &1.entries) |> Enum.count(&match?({:gone, _}, &1))

    seen = bump(seen, "tombstones applied", tombstones)

    # A removed name is in use if a declaration committed before the step, as
    # the spec has it, used it.
    uses =
      for [d, decl] <- map(var(prior, "committed")), [n, _] <- map(decl["uses"]) do
        {"M.#{d}", "M.#{n}"}
      end

    committed_now = Universe.committed(u)

    seen =
      committed_before
      |> Enum.reject(&Map.has_key?(committed_now, &1))
      |> Enum.reduce(seen, fn name, seen ->
        in_use = Enum.any?(uses, fn {d, n} -> d != name and n == name end)
        seen |> bump("names removed") |> bump("names removed in use", if(in_use, do: 1, else: 0))
      end)

    got = normalize(ex_concrete(u, action))
    want = normalize(spec_concrete(state))

    assert got == want,
           "step #{i} of a trace: got #{inspect(got, limit: :infinity)}\nwant #{inspect(want, limit: :infinity)}"

    cids = Map.new(committed_now, fn {n, c} -> {n, c.cid} end)

    assert Universe.replay(Universe.history(u)) == cids,
           "step #{i}: committed is the replay of history"

    {u, seen}
  end
end
