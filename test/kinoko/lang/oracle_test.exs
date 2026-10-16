defmodule Kinoko.Lang.OracleTest do
  @moduledoc """
  The checker against what the TS implementation says (the golden files
  under test/fixtures/yabu, ported from the Rust crate's `tests/golden.rs`
  and its `every_*_typechecks_as_in_ts` / `every_*_codes_and_deps_match_ts`
  tests).

  The fixtures' sources are already migrated to typed `Html<App.Msg>`; TS
  computed the verdicts, codes and deps on the source as written, with a bare
  `Html`. As in golden.rs, verdicts and error codes (in order) must match
  exactly, and our deps must hold all of TS's.

  golden.rs lets Rust's deps hold more, provided each extra name is a
  deftype of the program. Here the tolerance is narrower, and names the two
  causes of the extra names:

  - The typed-`Html` migration. A def that the migration rewrote to write
    `Html<App.Msg>` in its signature now reads `App.Msg` as a dependency, as
    it reads every name an annotation writes. The extra name must be
    `App.Msg` for an app `App` the program declares, written as
    `Html<App.Msg>` in that declaration's own signature.
  - The map-key rule (Rust-only; TS has none). It looks up every non-builtin
    name applied in a type it walks, so a declaration whose node types apply
    a stdlib deftype that TS never looked up (`Option`) depends on it. The
    extra name must be a stdlib deftype.

  Nothing else is tolerated. The number of declarations that gained a
  dependency is pinned per suite (golden.rs's `report_gained` prints it), so
  a new kind of gain fails here rather than passing unnoticed.
  """
  use ExUnit.Case, async: true

  alias Kinoko.Lang.{Ast, Parser}
  alias Kinoko.Lang.Types.{Check, Extract, Stdlib}

  defp parse(label, src) do
    case Parser.program(src) do
      {:ok, decls} -> decls
      {:error, e} -> flunk("#{label}: #{inspect(e)}")
    end
  end

  defp run(label, src) do
    decls = parse(label, src)
    {decls, Check.program(decls, Stdlib.signatures())}
  end

  defp codes(%{result: {:ok, _}}), do: []
  defp codes(%{result: {:error, e}}), do: Enum.map(e, & &1.code)

  @stdlib_deftypes for {n, {:type, _, _}} <- Stdlib.signatures(), into: MapSet.new(), do: n

  # The names the typed-Html migration may add to `decl`'s deps: `App.Msg`
  # for each app of the program whose `Html<App.Msg>` the declaration's own
  # signature writes.
  defp typed_html_gain(decl, apps) do
    case decl do
      {:def, _, [_, params, ret, _]} ->
        for t <- [ret | Enum.map(params, &elem(&1, 1))],
            msg <- html_messages(t),
            Extract.owner_of(msg) in apps,
            Extract.last_segment(msg) == "Msg",
            into: MapSet.new(),
            do: msg

      _ ->
        MapSet.new()
    end
  end

  defp html_messages({:applied, "Html", [{:named, msg}]}), do: [msg]
  defp html_messages({:applied, _, args}), do: Enum.flat_map(args, &html_messages/1)
  defp html_messages({:tuple, items}), do: Enum.flat_map(items, &html_messages/1)
  defp html_messages({:arrow, ps, r}), do: Enum.flat_map([r | ps], &html_messages/1)
  defp html_messages(_), do: []

  # One program's every declaration against TS's verdicts, codes and deps
  # (golden.rs's `assert_codes_and_deps_match`). Returns how many
  # declarations gained a dependency.
  defp assert_matches(label, src, %{"verdicts" => v, "codes" => c, "deps" => d}) do
    {decls, checked} = run(label, src)

    assert Enum.sort(Map.keys(checked)) == Enum.sort(Map.keys(v)),
           "#{label}: checked a different set of declarations than TS reported verdicts for"

    apps = for {:defapp, _, [name]} <- decls, into: MapSet.new(), do: name
    by_name = Map.new(decls, &{Ast.name(&1), &1})

    Enum.count(v, fn {name, ok?} ->
      got = checked[name]

      assert match?({:ok, _}, got.result) == ok?,
             "#{label}: `#{name}` verdict: #{inspect(got.result)}"

      assert codes(got) == Map.get(c, name, []),
             "#{label}: `#{name}` codes: #{inspect(got.result)}"

      want = MapSet.new(Map.get(d, name, []))
      missing = MapSet.difference(want, got.deps)

      assert MapSet.size(missing) == 0,
             "#{label}: `#{name}`: TS depends on #{inspect(missing)}, we do not"

      extra = MapSet.difference(got.deps, want)
      allowed = MapSet.union(typed_html_gain(by_name[name], apps), @stdlib_deftypes)

      assert MapSet.subset?(extra, allowed),
             "#{label}: `#{name}`: depends on #{inspect(MapSet.difference(extra, allowed))}, TS does not"

      MapSet.size(extra) > 0
    end)
  end

  test "every corpus declaration checks, with TS's codes and deps" do
    gained =
      for e <- YabuOracle.corpus(), reduce: 0 do
        n -> n + assert_matches(e["file"], YabuOracle.corpus_source(e["file"]), e)
      end

    # Split's two view helpers, `Split.view_expense` and `Split.view_share`,
    # send nothing, so TS never looked `Split.Msg` up; now their signatures
    # write `Html<Split.Msg>`. Every view of the corpus sends a message, so
    # TS has `App.Msg` for those already.
    assert gained == 2
  end

  test "every generated declaration checks, with TS's codes and deps" do
    programs = YabuOracle.generated()
    assert length(programs) >= 300

    gained =
      for p <- programs, reduce: 0 do
        n -> n + assert_matches("generated (seed #{p["seed"]})", p["source"], p)
      end

    # 100 views that send nothing gain `App.Msg`; 16 declarations gain
    # `Option` through the map-key rule.
    assert gained == 116
  end

  test "every ill-typed program fails exactly at its wrong declaration, with TS's codes and deps" do
    programs = YabuOracle.ill_typed()
    assert length(programs) >= 300

    gained =
      for {p, i} <- Enum.with_index(programs), reduce: 0 do
        acc ->
          label = "ill_typed[#{i}] (seed #{p["seed"]})"
          {_, checked} = run(label, p["source"])
          failing = for {n, %{result: {:error, _}}} <- checked, do: n
          assert failing == [p["wrong"]], "#{label}: failing #{inspect(failing)}"
          acc + assert_matches(label, p["source"], p)
      end

    # Each program's app view gains `App.Msg` (307); 13 declarations, 5 of
    # them failing ones, gain `Option` through the map-key rule.
    assert gained == 320
  end

  test "an unbound constructor message shows the %M{} syntax" do
    {:ok, [_, d]} =
      Parser.program("defmodel A.M do\n  n : Int\nend\n\ndef A.f() : A.M do\n  A.M(1)\nend")

    sigs = Map.merge(Stdlib.signatures(), %{"A.M" => {:model, [{"n", {:named, "Int"}, :none}]}})
    %{result: {:error, [e | _]}} = Check.decl(d, sigs)
    assert e.message =~ "%A.M{"
  end
end
