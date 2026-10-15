defmodule Kinoko.Lang.UniverseTest do
  @moduledoc """
  The universe against its reference, trying every subset and checking
  afresh, and the shapes and costs its mechanisms exist for (ported from
  `crates/yabu/src/universe/tests.rs`, every test, under its name).
  """
  use ExUnit.Case, async: true

  import Kinoko.Lang.UniverseCases, only: [parse: 1, patch: 1, entries: 1, play: 4, run: 3]

  alias Kinoko.Lang.{Ast, Cid, NaiveUniverse, Salsa, Universe, UniverseCases}
  alias Kinoko.Lang.Types.{Check, Extract, Stdlib}
  alias Kinoko.Lang.Universe.{Db, Search}

  defp gone(name), do: {:gone, name}
  defp stage(u, id, entries), do: Universe.stage(u, id, entries)
  defp names(u), do: u |> Universe.committed() |> Map.keys() |> Enum.sort()
  defp rounds(u), do: Enum.map(Universe.history(u), & &1.ids)

  # What history keeps of a round that applied `entries`.
  defp applied(entries) do
    entries
    |> Enum.map(fn
      {:live, d} -> {:live, Ast.name(d), Cid.of(d)}
      {:gone, n} -> {:gone, n}
    end)
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp decl(src), do: src |> parse() |> hd() |> Ast.without_positions()

  # Every reason concerns `name`, and the first has `code`.
  defp sole(reasons, name, code) do
    assert reasons != [] and Enum.all?(reasons, &(&1.name == name)), inspect(reasons)
    assert hd(reasons).code == code, inspect(reasons)
  end

  defp seconds(f) do
    {micro, value} = :timer.tc(f)
    {micro / 1_000_000, value}
  end

  # The declarations the database checked while `f` ran, by name, each as
  # often as it was checked, in name order (Rust's `checked_during`).
  defp checked_during(u, f) do
    before = Salsa.stats(u.salsa).computes
    {after_u, value} = f.(u)
    by_cid = cid_names(u) |> Map.merge(cid_names(after_u))

    checked =
      for {{:check, cid}, n} <- Salsa.stats(after_u.salsa).computes,
          n > Map.get(before, {:check, cid}, 0),
          _ <- 1..(n - Map.get(before, {:check, cid}, 0)),
          do: Map.fetch!(by_cid, cid)

    {Enum.sort(checked), after_u, value}
  end

  defp cid_names(u) do
    staged = for {_, p} <- u.staged, {:live, n, cid, _} <- p, into: %{}, do: {cid, n}
    Map.merge(staged, Map.new(u.committed, fn {n, c} -> {c.cid, n} end))
  end

  # `T.C00000<K>` holding `T.C00001<K>`, and so on: `length` deftypes whose
  # names run against the order they hold each other in, the last a `Map`
  # keyed by `K`.
  defp chain(length) do
    links =
      for i <- 0..(length - 2)//1, do: "deftype T.C#{pad(i)}<K> do A(T.C#{pad(i + 1)}<K>) end\n"

    Enum.join(links) <> "deftype T.C#{pad(length - 1)}<K> do A(Map<K, Int>) end\n"
  end

  defp pad(i), do: i |> Integer.to_string() |> String.pad_leading(5, "0")
  defp pad2(i), do: i |> Integer.to_string() |> String.pad_leading(2, "0")

  test "a well typed patch promotes whole" do
    {u, v} =
      stage(
        Universe.new(),
        "p1",
        patch("def M.a() : Int do M.b() + 1 end\ndef M.b() : Int do 1 end")
      )

    assert v == {:promoted, ["p1"]}
    assert names(u) == ["M.a", "M.b"]
    assert Universe.staged(u) == %{}
  end

  # TS: "a patch with a missing dep stays staged with a reason".
  test "a broken patch stays staged with reasons and changes nothing" do
    {u, v} = stage(Universe.new(), "p1", patch("def M.a() : Int do M.b() + 1 end"))

    assert v ==
             {:staged,
              [%{name: "M.a", code: "unbound", message: "there is no `M.b` — `M` has `M.a`"}]}

    assert Universe.committed(u) == %{}
    assert length(Universe.reasons(u, "p1")) == 1
  end

  # TS: "backward check: changing a sig with a committed dependent stays staged".
  test "a patch that would break a committed dependent is refused" do
    {u, _} =
      stage(
        Universe.new(),
        "p1",
        patch("def M.a() : Int do M.b() + 1 end\ndef M.b() : Int do 1 end")
      )

    {u, v} = stage(u, "p2", patch("def M.b() : String do \"one\" end"))

    assert v ==
             {:staged,
              [
                %{
                  name: "M.a",
                  code: "mismatch",
                  message: "type mismatch: expected Int, got String in `M.b()`"
                }
              ]}

    assert Universe.committed(u)["M.b"].decl == decl("def M.b() : Int do 1 end")
  end

  test "promoting one patch promotes the staged ones it unblocks" do
    {u, _} = stage(Universe.new(), "waits", patch("def M.a() : Int do M.b() end"))
    {u, v} = stage(u, "unblocks", patch("def M.b() : Int do 2 end"))
    assert v == {:promoted, ["unblocks", "waits"]}
    assert Universe.staged(u) == %{}
  end

  test "restaging an id replaces it and unstage drops it" do
    {u, _} = stage(Universe.new(), "p", patch("def M.a() : Int do M.missing() end"))
    {u, v} = stage(u, "p", patch("def M.a() : Int do 1 end"))
    assert v == {:promoted, ["p"]}
    {u, _} = stage(u, "q", patch("def M.c() : Int do M.missing() end"))
    assert {u, true} = Universe.unstage(u, "q")
    assert {u, false} = Universe.unstage(u, "q")
    assert Universe.staged(u) == %{}
  end

  test "duplicate names in one patch are a reason" do
    {_, v} =
      stage(Universe.new(), "p", patch("def M.a() : Int do 1 end\ndef M.a() : Int do 2 end"))

    assert v ==
             {:staged,
              [%{name: "M.a", code: "duplicate", message: "defined twice in this patch"}]}
  end

  # `M.n` never names `M.Box`: its check reaches the model through
  # `M.boxes`'s return type. Linked by what it names alone, it would not be
  # checked, and changing the model would break it.
  test "a model reached only through a signature is checked" do
    base = """
    defmodel M.Box do
      n : Int
    end

    def M.boxes() : List<M.Box> do [] end

    def M.n() : Int do
      case List.head(M.boxes()) do
        Option.Some(b) -> b.n
        Option.None -> 0
      end
    end
    """

    {u, {:promoted, _}} = stage(Universe.new(), "base", patch(base))
    {_, {:staged, reasons}} = stage(u, "p", patch("defmodel M.Box do\n  n : String\nend"))
    sole(reasons, "M.n", "mismatch")
  end

  # `M.c` reaches `M.Inner` only through the map-key rule, which consults
  # `M.W`'s variants: a `Map` keyed by `M.Inner`'s parameter breaks it.
  test "a deftype reached only through the map key rule is checked" do
    base = """
    deftype M.Inner<K> do I(K) end

    deftype M.W<K> do W(M.Inner<K>) end

    def M.c(w : M.W<(Int -> Int)>) : Int do 1 end
    """

    {u, {:promoted, _}} = stage(Universe.new(), "base", patch(base))
    {u, {:staged, why}} = stage(u, "p", patch("deftype M.Inner<K> do I(Map<K, Int>) end"))
    sole(why, "M.c", "non-data-map-key")
    assert NaiveUniverse.reasons(Universe.committed(u), []) == []
  end

  # `M.view` sends `M.Msg.Go`: a patch that takes `Go` out of `M.Msg` breaks
  # it, and is refused.
  test "rust only: a patch removing a message the view sends is refused" do
    app = """
    defmodel M.Model do
      n : Int
    end

    deftype M.Msg do
      Go | Stop
    end

    def M.init() : (M.Model, Cmd<M.Msg>) do (%M.Model{n: 0}, Cmd.none()) end

    def M.update(msg : M.Msg, model : M.Model) : (M.Model, Cmd<M.Msg>) do (model, Cmd.none()) end

    def M.view(model : M.Model) : Html<M.Msg> do <button on-click={M.Msg.Go}>go</button> end

    defapp M
    """

    {u, {:promoted, _}} = stage(Universe.new(), "app", patch(app))
    {_, {:staged, reasons}} = stage(u, "p", patch("deftype M.Msg do\n  Stop\nend"))
    sole(reasons, "M.view", "unbound")
  end

  # A chain of 2,000 deftypes, each holding the next by name, the last a
  # `Map` keyed by its parameter, stages as quickly as any patch, and a
  # function passed to its first deftype still reaches the last one's key.
  # Rust's debug bound, 1 s; staging measured here at ~65 ms.
  @tag :perf
  test "a long chain of deftypes stages quickly" do
    staged = patch(chain(2000))
    {took, {u, v}} = seconds(fn -> stage(Universe.new(), "chain", staged) end)
    assert {:promoted, _} = v
    assert took < 1.0, "took #{took}"

    {_, {:staged, reasons}} =
      stage(u, "f", patch("def T.f(c : T.C00000<(Int -> Int)>) : Int do 1 end"))

    sole(reasons, "T.f", "non-data-map-key")
  end

  # A fan of 10,000 deftypes, `T.Z<K, V>` holding each of `T.L00000<K, V>`
  # to `T.L09999<K, V>`, every leaf a `Map<K, V>`, stages in time linear in
  # its size, with a def passing the fan a function as `V`. One passing it a
  # function as `K` is refused. The def depends on every leaf, so a leaf
  # that comes to be keyed by `V` is refused too: it would break the def.
  # Rust's debug bound, 10 s; staging measured here at ~1 s.
  @tag timeout: 120_000
  @tag :perf
  test "a wide fan of deftypes stages quickly" do
    leaves = 10_000
    leaf = fn i -> "deftype T.L#{pad(i)}<K, V> do A(Map<K, V>) end\n" end
    variants = Enum.map_join(0..(leaves - 1), " | ", &"V#{pad(&1)}(T.L#{pad(&1)}<K, V>)")
    source = Enum.map_join(0..(leaves - 1), leaf) <> "deftype T.Z<K, V> do #{variants} end\n"
    fan = patch(source <> "def T.f(z : T.Z<Int, (Int -> Int)>) : Int do 1 end")
    {took, {u, v}} = seconds(fn -> stage(Universe.new(), "fan", fan) end)
    assert {:promoted, _} = v
    assert took < 10.0, "took #{took}"
    assert MapSet.size(Universe.committed(u)["T.f"].deps) == leaves + 1

    {u, {:staged, reasons}} =
      stage(u, "g", patch("def T.g(z : T.Z<(Int -> Int), Int>) : Int do 1 end"))

    sole(reasons, "T.g", "non-data-map-key")

    {_, {:staged, reasons}} =
      stage(u, "leaf", patch("deftype T.L05000<K, V> do A(Map<V, K>) end"))

    sole(reasons, "T.f", "non-data-map-key")
  end

  # A patch as large as the environment takes (256 KB) of references that do
  # not resolve, over 10,000 committed declarations, stages in time linear in
  # its size: what each reference's message says is looked up in the table,
  # never scanned out of it. Rust's debug bound, 10 s; measured here at
  # ~0.4 s (25 s before sibling names were looked up in a sorted table).
  @tag timeout: 120_000
  @tag :perf
  test "a patch of unbound references over a large table stages quickly" do
    committed = Enum.map_join(0..9_999, &"def M.d#{pad(&1)}() : Int do 1 end\n")
    {u, {:promoted, _}} = stage(Universe.new(), "base", patch(committed))

    reference = fn i ->
      case rem(i, 5) do
        0 -> "M.u#{pad(i)}"
        1 -> "u#{pad(i)}"
        2 -> "M.D#{pad(rem(i, 10_000))}"
        3 -> "d#{pad(rem(i, 10_000))}"
        _ -> "M.same"
      end
    end

    references =
      Stream.iterate(0, &(&1 + 1))
      |> Enum.reduce_while({[], 0}, fn i, {refs, bytes} ->
        if bytes < 256 * 1024 - 64,
          do: {:cont, {[reference.(i) | refs], bytes + byte_size(reference.(i)) + 2}},
          else: {:halt, {Enum.reverse(refs), bytes}}
      end)
      |> elem(0)

    source = "def N.f() : List<Int> do\n  [#{Enum.join(references, ", ")}]\nend"
    assert byte_size(source) <= 256 * 1024
    staged = patch(source)
    {took, {_, v}} = seconds(fn -> stage(u, "references", staged) end)
    {:staged, reasons} = v
    assert took < 10.0, "took #{took}"
    siblings = Enum.map_join(0..7, ", ", &"`M.d#{pad(&1)}`")

    first = [
      "there is no `M.u00000` — `M` has #{siblings}, …",
      "unbound symbol `u00001`",
      "`M.D00002` is not in scope — `M.d00002` is what you want — every name is fully qualified, so write `M.d00002`",
      "`d00003` is not in scope — `M.d00003` is what you want — every name is fully qualified, so write `M.d00003`"
    ]

    assert reasons |> Enum.take(4) |> Enum.map(& &1.message) == first
    assert Enum.all?(reasons, &(&1.name == "N.f" and &1.code == "unbound"))
    assert length(reasons) == length(references)
  end

  test "one rule says which names the language provides" do
    for name <- ["List.map", "Cmd.none", "Int", "List", "Map"], do: assert(Stdlib.provided?(name))
    for name <- ["A.f", "Lists", "List.nope"], do: refute(Stdlib.provided?(name))
    assert Stdlib.signature("List.map") == Stdlib.signatures()["List.map"]
    assert Stdlib.signature("A.f") == nil

    deps =
      Db.deps(decl("def A.f(x : Int) : Int do\n  List.length([x]) + A.g()\nend"), %{
        deps: MapSet.new(["Int", "List.length", "A.g"]),
        result: {:ok, nil}
      })

    assert deps == MapSet.new(["A.g"])
  end

  # Removing a name thousands of committed declarations use: each breaks,
  # and each one's reasons are worded from the whole table. The table's
  # sorted names and name index are built once for all of them, never once
  # per broken declaration (1.3/5.4/22.6 s for 1,000/2,000/4,000 before).
  @tag timeout: 120_000
  @tag :perf
  test "removing a name thousands of declarations use stages quickly" do
    users = Enum.map_join(0..3_999, &"def M.u#{pad(&1)}() : Int do\n  M.base()\nend\n")
    source = "def M.base() : Int do\n  1\nend\n" <> users
    {u, {:promoted, _}} = stage(Universe.new(), "base", patch(source))

    {took, {_, {:staged, reasons}}} = seconds(fn -> stage(u, "rm", [gone("M.base")]) end)
    assert took < 2.0, "took #{took}"
    assert length(reasons) == 4_000
    assert Enum.all?(reasons, &(&1.code == "unbound"))
  end

  # A broken declaration's reasons are the database check's errors, each
  # unbound name's message reworded from the whole table: exactly what a
  # fresh check against that table says.
  test "reasons of broken declarations are a fresh check's over the whole table" do
    source = """
    def M.base() : Int do
      1
    end

    def M.other() : Int do
      2
    end

    def M.a() : Int do
      M.base() + M.other()
    end

    def M.c(n : Int) : Int do
      M.base() + n
    end
    """

    {u, {:promoted, _}} = stage(Universe.new(), "base", patch(source))
    model = decl("defmodel M.Base do\n  count : Int\nend")

    for {id, entries, says} <- [
          {"rm", [gone("M.base")], "there is no `M.base` — `M` has"},
          {"model", [gone("M.base"), {:live, model}], "`M.Base` is a model"}
        ] do
      {u, {:staged, reasons}} = stage(u, id, entries)
      changes = for {:live, d} <- entries, do: {Ast.name(d), Extract.signature(d)}
      sigs = Universe.over(Universe.signatures(u), [{"M.base", nil} | changes])

      fresh =
        for name <- ["M.a", "M.c"],
            {:error, errors} = Check.decl(Universe.committed(u)[name].decl, sigs).result,
            e <- errors,
            do: %{name: name, code: e.code, message: e.message}

      assert reasons == fresh
      assert length(reasons) == 2
      assert Enum.all?(reasons, &String.contains?(&1.message, says)), inspect(reasons)
    end
  end

  # An agent retries `M.f` under a fresh id each time, every attempt refused
  # for breaking `M.c`. The attempts all define `M.f`, so they form a clique,
  # and no two of them merge: each stages in time linear in how many came
  # before, and so does an edit of `M.c`'s body after them, which promotes.
  @tag :perf
  test "retrying one function under fresh ids stages quickly" do
    {u, _} =
      stage(
        Universe.new(),
        "base",
        patch("def M.f() : Int do 1 end\ndef M.c() : Int do M.f() + 1 end")
      )

    {took, u} =
      seconds(fn ->
        u =
          Enum.reduce(0..16, u, fn i, u ->
            {u, {:staged, reasons}} =
              stage(u, "try#{pad2(i)}", patch("def M.f() : String do \"#{i}\" end"))

            sole(reasons, "M.c", "mismatch")
            u
          end)

        {u, v} = stage(u, "edit", patch("def M.c() : Int do M.f() + 2 end"))
        assert v == {:promoted, ["edit"]}
        u
      end)

    assert took < 5.0, "took #{took}"
    assert map_size(Universe.staged(u)) == 17
  end

  # An agent sends one refused patch again, each time under a fresh id. The
  # copies merge, being one patch, but each fails on its own over what no
  # other staged patch touches, so no set of them is tried. So does a fixed
  # version under the last copy's id, which promotes alone.
  @tag :perf
  test "an identical patch resent under fresh ids stages quickly" do
    {took, u} =
      seconds(fn ->
        u =
          Enum.reduce(0..17, Universe.new(), fn i, u ->
            {u, {:staged, reasons}} =
              stage(u, "copy#{pad2(i)}", patch("def M.g() : Int do M.missing() + 1 end"))

            sole(reasons, "M.g", "unbound")
            u
          end)

        {u, v} = stage(u, "copy17", patch("def M.g() : Int do 1 end"))
        assert v == {:promoted, ["copy17"]}
        u
      end)

    assert took < 5.0, "took #{took}"
    assert map_size(Universe.staged(u)) == 17
  end

  # Copies of one patch, each under its own id, wait for a name; once it is
  # staged, every copy promotes with it, in one round that applies the patch
  # once. The search tries the copies as one.
  @tag :perf
  test "copies of a patch promote with their fix quickly" do
    copies = for i <- 0..17, do: "copy#{pad2(i)}"
    copy = patch("def M.g() : Int do M.missing() + 1 end")

    u =
      Enum.reduce(copies, Universe.new(), fn id, u ->
        {u, {:staged, _}} = stage(u, id, copy)
        u
      end)

    fix = patch("def M.missing() : Int do 1 end")
    {took, {u, v}} = seconds(fn -> stage(u, "fix", fix) end)
    assert v == {:promoted, copies ++ ["fix"]}
    assert rounds(u) == [copies ++ ["fix"]]
    assert hd(Universe.history(u)).entries == applied(copy ++ fix)
    assert Universe.staged(u) == %{}
    assert took < 5.0, "took #{took}"
  end

  # A helper is staged broken, then callers of it, each in a patch of its
  # own: a star around the helper. Once the helper is fixed, under its own
  # id, everything promotes with it.
  @tag :perf
  test "callers of a broken helper each in its own patch stage quickly" do
    callers = for i <- 0..17, do: "caller#{pad2(i)}"

    {took, u} =
      seconds(fn ->
        {u, {:staged, _}} =
          stage(Universe.new(), "helper", patch("def M.h() : Int do M.missing() end"))

        u =
          callers
          |> Enum.with_index()
          |> Enum.reduce(u, fn {id, i}, u ->
            {u, {:staged, reasons}} =
              stage(u, id, patch("def M.c#{pad2(i)}() : Int do M.h() + #{i} end"))

            sole(reasons, "M.c#{pad2(i)}", "unbound")
            u
          end)

        {u, v} = stage(u, "helper", patch("def M.h() : Int do 1 end"))
        assert v == {:promoted, callers ++ ["helper"]}
        u
      end)

    assert length(rounds(u)) == 1
    assert took < 5.0, "took #{took}"
  end

  # Two patches define `M.hub` differently, each failing alone, each touching
  # what the other does, so neither is dropped. Twelve callers of `M.hub`
  # (Rust stages sixteen; each caller's own stage enumerates 2^k sets, as in
  # Rust, untimed, so twelve keeps the suite fast)
  # stage around them. Then a root is staged whose second declaration fails
  # alone over what nothing else touches, so `alive` drops the root alone,
  # and the part ends at once.
  @tag :perf
  test "a dead root beside live callers is refused quickly" do
    {u, {:staged, _}} =
      stage(Universe.new(), "huba", patch("def M.hub() : Int do M.missing_a() end"))

    {u, {:staged, _}} = stage(u, "hubb", patch("def M.hub() : Int do M.missing_b() end"))

    u =
      Enum.reduce(0..11, u, fn i, u ->
        {u, {:staged, reasons}} =
          stage(u, "caller#{pad2(i)}", patch("def M.c#{pad2(i)}() : Int do M.hub() + #{i} end"))

        sole(reasons, "M.c#{pad2(i)}", "unbound")
        u
      end)

    root =
      "def M.croot() : Int do M.hub() + 999 end\ndef M.deadthing() : Int do M.totally_isolated_xyz() end"

    {took, {u, v}} = seconds(fn -> stage(u, "dead", patch(root)) end)
    {:staged, reasons} = v

    assert Enum.any?(reasons, &(&1.name == "M.deadthing" and &1.code == "unbound")),
           inspect(reasons)

    assert took < 5.0, "took #{took}"
    assert map_size(Universe.staged(u)) == 15
  end

  # A failed check stops early: `M.Box` is unbound, so the field values are
  # never checked and `M.k` is never consulted. What the declaration names
  # links it all the same.
  test "a failed check depends on what the declaration names too" do
    d = decl("def M.f() : Int do %M.Box{n: M.k()} end")
    checked = Check.decl(d, Stdlib.signatures())
    assert {:error, _} = checked.result
    refute MapSet.member?(checked.deps, "M.k")
    assert Db.deps(d, checked) == MapSet.new(["M.Box", "M.k"])
  end

  @base "def M.x() : Int do 1 end\ndef M.y() : Int do 2 end"

  # The root's own body needs both components: `++` needs both sides String.
  test "a root that uses two staged patches promotes with both" do
    {u, _} =
      stage(Universe.new(), "base", patch("#{@base}\ndef M.z() : Int do M.x() + M.y() end"))

    {u, {:staged, _}} = stage(u, "t1", patch("def M.x() : String do \"a\" end"))
    {u, {:staged, _}} = stage(u, "t2", patch("def M.y() : String do \"b\" end"))
    {_, v} = stage(u, "r", patch("def M.z() : String do M.x() ++ M.y() end"))
    assert v == {:promoted, ["r", "t1", "t2"]}
  end

  # The root breaks two committed callers, each fixed by its own patch.
  test "a root that breaks two callers promotes with both fixes" do
    {u, _} =
      stage(
        Universe.new(),
        "base",
        patch("#{@base}\ndef M.b() : Int do M.x() + 1 end\ndef M.e() : Int do M.x() * 2 end")
      )

    {u, {:staged, _}} = stage(u, "fix_b", patch("def M.b() : String do M.x() ++ \"!\" end"))
    {u, {:staged, _}} = stage(u, "fix_e", patch("def M.e() : String do M.x() end"))
    {_, v} = stage(u, "r", patch("def M.x() : String do \"a\" end"))
    assert v == {:promoted, ["fix_b", "fix_e", "r"]}
  end

  # TS leaves `a` staged with no reason here, because the broken `b` is
  # dragged into its trial.
  test "a patch that typechecks alone is never held back by a broken one" do
    {u, _} = stage(Universe.new(), "base", patch("def M.b() : Int do 1 end"))
    {u, {:staged, _}} = stage(u, "b", patch("def M.b() : String do M.missing() end"))
    {_, v} = stage(u, "a", patch("def M.c() : Int do M.b() + 1 end"))
    assert v == {:promoted, ["a"]}
  end

  # `T.g` reaches `T.A` only through `p3`'s `T.C`, by the map-key rule:
  # committed, it consults `T.C` alone. So `p3` is refused while `T.A` holds
  # a `Map`, and promotes with the patch that takes it out, in one round.
  test "a patch promotes with the round that enables it through a name only its context reaches" do
    base = """
    deftype T.A<K> do A(Map<K, Int>) end
    deftype T.B<K> do B(T.A<K>) end
    deftype T.C<K> do C(K) end
    def T.g(c : T.C<(Int -> Int)>) : Int do 1 end
    """

    {u, {:promoted, _}} = stage(Universe.new(), "base", patch(base))
    {u, {:staged, why}} = stage(u, "p3", patch("deftype T.C<K> do C(T.B<K>) end"))
    sole(why, "T.g", "non-data-map-key")
    {u, v} = stage(u, "p4", patch("deftype T.A<K> do A(K) end"))
    assert v == {:promoted, ["p3", "p4"]}
    assert rounds(u) == [["base"], ["p3", "p4"]]
    assert Universe.staged(u) == %{}
  end

  # The spec's `disjoint` holds for the same patch under two ids: they
  # promote together, as one round that applies it once.
  test "the same patch under two ids promotes as one" do
    same = "def M.b() : Int do M.a() end"
    {u, {:staged, _}} = stage(Universe.new(), "p1", patch(same))
    {u, {:staged, _}} = stage(u, "p2", patch(same))
    {u, v} = stage(u, "p3", patch("def M.a() : Int do 1 end"))
    assert v == {:promoted, ["p1", "p2", "p3"]}
    assert rounds(u) == [["p1", "p2", "p3"]]

    assert hd(Universe.history(u)).entries ==
             applied(patch("def M.a() : Int do 1 end") ++ patch(same))
  end

  # `p0` removes `M.b`, which `M.c` uses; `p1` removes `M.b` and moves `M.c`
  # off it. They touch the same name, so `p1` promotes alone; then `p0`
  # removes nothing, and promotes in a round of its own.
  test "a tombstone promotes once another patch removed its name" do
    {u, _} =
      stage(
        Universe.new(),
        "base",
        patch("def M.b() : Int do 1 end\ndef M.c() : Int do M.b() end")
      )

    {u, {:staged, _}} = stage(u, "p0", [gone("M.b")])
    {u, v} = stage(u, "p1", [gone("M.b") | patch("def M.c() : Int do 2 end")])
    assert v == {:promoted, ["p1", "p0"]}
    assert rounds(u) == [["base"], ["p1"], ["p0"]]
    assert Universe.staged(u) == %{}
  end

  # A patch that defines a stdlib name (refused, for its name) gives that
  # name its own signature in the whole table, so `M.n`, which calls the
  # stdlib's, breaks; stdlib names are no committed declaration's
  # dependencies, so it is found only by checking all committed code.
  test "rust only: a patch defining a stdlib name is refused for what calls the stdlib's" do
    {u, {:promoted, _}} =
      stage(Universe.new(), "base", patch("def M.n() : Int do List.length([1]) end"))

    p = patch("def List.length(x : Int) : Int do x end")
    {u, {:staged, why}} = stage(u, "p", p)
    assert [%{name: "List.length", code: "bad-name"}, %{name: "M.n", code: "mismatch"}] = why
    assert why == NaiveUniverse.reasons(Universe.committed(u), p)
  end

  # A tombstone removes a committed name, and the stdlib has none: its names
  # stay, for the patch's own declarations too.
  test "rust only: a tombstone never removes a stdlib name" do
    p = [gone("List.length") | patch("def M.n() : Int do List.length([1]) end")]
    assert {_, {:promoted, ["p"]}} = stage(Universe.new(), "p", p)
  end

  # Early cutoff: an edit of `M.x`'s body keeps its signature, so the
  # database checks `M.x` alone, never the committed declarations that call
  # it; an edit of its signature checks them again.
  test "rust only: a body edit checks only that declaration, never its dependents" do
    base =
      "def M.x() : Int do 1 end\ndef M.d() : Int do M.x() + 1 end\ndef M.e() : Int do M.x() * 2 end"

    {u, _} = stage(Universe.new(), "base", patch(base))
    {checked, u, v} = checked_during(u, &stage(&1, "body", patch("def M.x() : Int do 2 end")))
    assert {:promoted, _} = v
    assert checked == ["M.x"]

    {checked, _, v} =
      checked_during(u, &stage(&1, "sig", patch("def M.x() : String do \"s\" end")))

    assert {:staged, _} = v
    assert checked == ["M.d", "M.e", "M.x"]
  end

  test "compute counts stay bounded while check_count keeps growing" do
    {u, _} = stage(Universe.new(), "base", patch("def M.x() : Int do 1 end"))

    sizes =
      for round <- 1..5 do
        u =
          Enum.reduce(1..100, u, fn i, u ->
            {u, {:staged, _}} =
              stage(u, "w", patch("def M.w#{round}x#{i}() : Int do M.x() + M.u#{i}() end"))

            u |> Universe.unstage("w") |> elem(0)
          end)
          |> Universe.collect(true)

        {map_size(Salsa.stats(u.salsa).computes), Universe.check_count(u)}
      end

    assert Enum.all?(sizes, fn {size, _} -> size <= 10 end), inspect(sizes)
    assert Enum.all?(sizes, fn {_, checks} -> checks >= 100 end), inspect(sizes)

    {u, _} =
      Enum.reduce(1..300, {u, nil}, fn i, {u, _} ->
        {u, _} = stage(u, "w", patch("def M.v#{i}() : Int do M.x() + M.u#{i}() end"))
        Universe.unstage(u, "w")
      end)

    u = Universe.collect(u, true)
    assert map_size(Salsa.stats(u.salsa).computes) <= 10
    assert Universe.check_count(u) >= 300
  end

  test "a body edit checks only that declaration, never its dependents (a chain of 20)" do
    chain =
      Enum.map_join(0..19, "\n", fn
        0 -> "def A.f0() : Int do 1 end"
        i -> "def A.f#{i}() : Int do A.f#{i - 1}() + 1 end"
      end)

    {u, {:promoted, _}} = stage(Universe.new(), "base", patch(chain))
    before = Universe.check_count(u)
    {u, {:promoted, _}} = stage(u, "edit", patch("def A.f0() : Int do\n  41 + 1\nend"))
    assert Universe.check_count(u) - before == 1
  end

  # `M.x` changes type under `M.d`, which takes it all the same. The search
  # tries `q` with it first (`q` waits for `M.x` and never typechecks), then
  # it alone: two contexts, in each of which `M.d` consults the same
  # signatures, so it is checked once.
  test "rust only: within one search a declaration consulting the same signatures is checked once" do
    {u, _} =
      stage(
        Universe.new(),
        "base",
        patch("def M.x() : List<Int> do [1] end\ndef M.d() : Int do List.length(M.x()) end")
      )

    {u, {:staged, _}} =
      stage(u, "q", patch("def M.w() : Int do List.length(M.x()) + M.missing() end"))

    {checked, u, v} =
      checked_during(u, &stage(&1, "r", patch("def M.x() : List<String> do [\"a\"] end")))

    assert v == {:promoted, ["r"]}
    # `M.w`, in the first trial only: it fails there, and the second is `r` alone.
    assert checked == ["M.d", "M.w", "M.x"]
    d = Universe.committed(u)["M.d"]
    assert {:ok, d.typed} == Check.decl(d.decl, Universe.signatures(u)).result
  end

  # Every check the database runs reads through it the signature of every
  # name it consulted: absent ones too, and those the map-key rule walks,
  # each directly or as one of a group it read settled. `Db` raises on a
  # check that does not; this plays cases through it and counts the checks.
  test "rust only: every check reads every signature it consults" do
    :rand.seed(:exsss, {11, 12, 13})

    {checks, consulting} =
      Enum.reduce(1..200, {0, 0}, fn i, {checks, consulting} ->
        {base, ops} =
          if rem(i, 2) == 0, do: UniverseCases.random_case(), else: UniverseCases.typed_case()

        {u, consulting} =
          play(base, ops, consulting, fn _, _, _, after_u, c -> c + consulting_memos(after_u) end)

        {checks + Universe.check_count(u), consulting}
      end)

    assert checks >= 1500 and consulting >= 1500,
           "#{checks} checks, #{consulting} memos consulting a declaration"
  end

  # The check memos the database holds that read a declaration's signature
  # (not the stdlib's), directly or through a group.
  defp consulting_memos(u) do
    for {{:check, _}, kept} <- u.salsa.memos, {memo, _} <- kept, reduce: 0 do
      n ->
        reads_declaration =
          Enum.any?(memo.reads, fn
            {:query, {:sig, name}, _} -> String.starts_with?(name, ["T.", "M."])
            {:query, {:reaching, _}, _} -> true
            _ -> false
          end)

        if reads_declaration, do: n + 1, else: n
    end
  end

  # `M.f` meets `M.Box` only in the type of `[M.g()]`, which the map-key rule
  # walks: it consults it without looking it up, and reads it all the same.
  test "rust only: a check reads a type it meets only in an inferred type" do
    {u, _} =
      stage(
        Universe.new(),
        "base",
        patch("deftype M.Box<K> do B(K) end\ndef M.g() : M.Box<Int> do M.Box.B(1) end")
      )

    {checked, u, v} =
      checked_during(u, &stage(&1, "f", patch("def M.f() : Int do List.length([M.g()]) end")))

    assert {:promoted, _} = v
    assert checked == ["M.f"]
    cid = Universe.committed(u)["M.f"].cid
    [{memo, _} | _] = u.salsa.memos[{:check, cid}]
    {:ok, outcome} = memo.value

    read =
      for {:query, q, {:ok, value}} <- memo.reads, reduce: MapSet.new() do
        read ->
          case q do
            {:sig, name} -> MapSet.put(read, name)
            {:reaching, _} -> MapSet.union(read, value.names)
            _ -> read
          end
      end

    assert MapSet.member?(outcome.deps, "M.Box") and MapSet.member?(read, "M.Box")
  end

  # Memos of declarations that come and go do not pile up. The database
  # never holds memos for many more queries than the code needs, and once it
  # drops what nothing holds, it holds the committed declaration's alone.
  @tag timeout: 120_000
  test "rust only: the memos stay bounded however many patches come and go" do
    {u, _} = stage(Universe.new(), "base", patch("def M.x() : Int do 1 end"))

    {u, most} =
      Enum.reduce(0..499, {u, 0}, fn i, {u, most} ->
        {u, {:staged, _}} =
          stage(u, "waits", patch("def M.w#{i}() : Int do M.x() + M.u#{i}() end"))

        {u, true} = Universe.unstage(u, "waits")
        {u, {:promoted, _}} = stage(u, "comes", patch("def M.c#{i}() : Int do M.x() + #{i} end"))
        {u, {:promoted, _}} = stage(u, "goes", [gone("M.c#{i}")])
        {u, {:promoted, _}} = stage(u, "edit", patch("def M.x() : Int do #{i} end"))
        {u, max(most, Salsa.stats(u.salsa).memos)}
      end)

    assert names(u) == ["M.x"]
    assert most <= 150, "the database held #{most} memos"
    u = Universe.collect(u, true)
    # `M.x`'s check and signature.
    assert Salsa.stats(u.salsa).memos == 2
    assert MapSet.size(u.cas) == 1
  end

  # A deftype group is settled once in a context, as a query of its own,
  # however many checks consult it: the 60 defs passing `T.Z` a function
  # each read it, not its 300 leaves' signatures one by one. A leaf that
  # comes to be keyed by `V` breaks every def; once each such patch is
  # dropped, what was kept for its context goes too.
  @tag timeout: 120_000
  test "rust only: a deftype group settles once however many checks consult it" do
    {leaves, users} = {300, 60}
    leaf = fn i -> "deftype T.L#{pad(i)}<K, V> do A(Map<K, V>) end\n" end
    variants = Enum.map_join(0..(leaves - 1), " | ", &"V#{pad(&1)}(T.L#{pad(&1)}<K, V>)")

    user = fn j ->
      "def T.u#{String.pad_leading("#{j}", 3, "0")}(z : T.Z<Int, (Int -> Int)>) : Int do #{j} end\n"
    end

    source =
      Enum.map_join(0..(leaves - 1), leaf) <>
        "deftype T.Z<K, V> do #{variants} end\n" <> Enum.map_join(0..(users - 1), user)

    {u, {:promoted, _}} = stage(Universe.new(), "fan", patch(source))
    reads = Salsa.stats(u.salsa).reads
    assert reads <= 8 * (leaves + users), "#{reads} reads"

    u =
      Enum.reduce(0..5, u, fn k, u ->
        {u, {:staged, reasons}} =
          stage(u, "leaf", patch("deftype T.L#{pad(k * 50)}<K, V> do A(Map<V, K>) end"))

        assert reasons |> Enum.map(& &1.name) |> Enum.uniq() |> length() == users
        assert Enum.all?(reasons, &(&1.code == "non-data-map-key"))
        {u, true} = Universe.unstage(u, "leaf")
        u
      end)

    u = Universe.collect(u, true)
    assert Salsa.stats(u.salsa).reads <= reads
  end

  # The empty id names what a promotion changed, never a patch: staging
  # under it is refused, whatever the patch would do, and stages nothing.
  test "rust only: the empty id is refused and stages nothing" do
    refused =
      {:staged,
       [
         %{
           name: nil,
           code: "bad-id",
           message: "a patch needs an id: the empty one names what a promotion changed"
         }
       ]}

    {u, v} = stage(Universe.new(), "", patch("def M.a() : Int do 1 end"))
    assert v == refused
    {u, _} = stage(u, "base", patch("def M.b() : Int do 1 end\ndef M.c() : Int do M.b() end"))
    assert {u, ^refused} = stage(u, "", patch("def M.b() : String do \"s\" end"))
    assert {u, ^refused} = stage(u, "", [gone("M.c")])
    assert Universe.staged(u) == %{}
    assert {names(u), rounds(u)} == {["M.b", "M.c"], [["base"]]}
    assert Universe.reasons(u, "") == []
    assert {_, false} = Universe.unstage(u, "")
  end

  # A declaration's CID is worked out once, when it is staged, and travels
  # with it, into committed code and history.
  test "rust only: a declaration keeps the cid it was staged with" do
    [{:live, d}] = p = patch("def M.a() : Int do 1 end")
    cid = Cid.of(d)
    {u, v} = stage(Universe.new(), "p", p)
    assert v == {:promoted, ["p"]}
    assert Universe.committed(u)["M.a"].cid == cid
    assert [%{entries: [{:live, "M.a", ^cid}]}] = Universe.history(u)
    assert Cid.of(Universe.committed(u)["M.a"].decl) == cid
  end

  # What storage keeps, history and the declarations by CID, restores the
  # same universe: committed code with each check, the signatures, and
  # history. Storage that is not what history replays to is refused, saying
  # why; code that does not typecheck is restored degraded.
  test "rust only: restoring history and the code it replays to gives the same universe" do
    sources = [
      "def M.a() : Int do 1 end\ndef M.b() : Int do M.a() end",
      "def M.a() : Int do 2 end",
      "def M.c() : Int do M.a() end"
    ]

    decls =
      Map.new(for(src <- sources, {:live, d} <- patch(src), do: {Cid.of(d), d}))

    {u, _} = stage(Universe.new(), "base", patch(Enum.at(sources, 0)))
    {u, _} = stage(u, "edit", patch(Enum.at(sources, 1)))
    {u, _} = stage(u, "drop", [gone("M.b") | patch(Enum.at(sources, 2))])

    {:ok, restored} = Universe.restore(Universe.history(u), [], decls)
    assert Universe.committed(restored) == Universe.committed(u)
    assert Universe.history(restored) == Universe.history(u)
    assert Universe.signatures(restored) == Universe.signatures(u)
    assert Universe.staged(restored) == %{}
    # Declarations history does not reference are ignored.
    assert {:ok, _} =
             Universe.restore(Universe.history(u), [], Map.put(decls, "unreferenced", :junk))

    # Layout is not content: a declaration parsed from loose text is the CID.
    a = Universe.committed(u)["M.a"].cid
    [{:live, loose}] = patch("def   M.a() : Int do\n  2\nend")
    {:ok, relaid} = Universe.restore(Universe.history(u), [], Map.put(decls, a, loose))
    assert Universe.committed(relaid) == Universe.committed(u)
    assert {:ok, empty} = Universe.restore([], [], %{})
    assert Universe.committed(empty) == %{}

    # An older history restores the code it replays to.
    {:ok, older} = Universe.restore(Enum.take(Universe.history(u), 2), [], decls)
    assert names(older) == ["M.a", "M.b"]

    c = Universe.committed(u)["M.c"].cid
    {:error, missing} = Universe.restore(Universe.history(u), [], Map.delete(decls, c))
    assert [%{name: nil, code: "restore", message: message}] = missing
    assert message =~ c

    [{:live, three}] = patch("def M.c() : Int do 3 end")
    {:error, wrong} = Universe.restore(Universe.history(u), [], Map.put(decls, c, three))
    assert [%{name: "M.c", code: "restore"}] = wrong

    [{:live, broken}] = patch("def M.b() : Int do M.missing() end")
    history = [%{ids: ["p"], entries: [{:live, "M.b", Cid.of(broken)}]}]
    # Code that no longer typechecks is restored degraded, as stored.
    {:degraded, degraded, why} = Universe.restore(history, [], %{Cid.of(broken) => broken})
    sole(why, "M.b", "unbound")
    assert Universe.degraded(degraded) == why
    assert Universe.history(degraded) == history
  end

  # ---------- TS's universe.test.ts, the cases that agree with the spec ----------

  test "a self contained patch promotes immediately" do
    {u, v} = stage(Universe.new(), "p1", patch("def M.a() : Int do 1 end"))
    assert v == {:promoted, ["p1"]}
    assert names(u) == ["M.a"]
    assert rounds(u) == [["p1"]]
  end

  # Any one of the three changed alone breaks the other two.
  test "multi symbol patch promotes atomically (the counter msg scenario)" do
    counter = fn msg ->
      """
      deftype M.Msg do #{msg} end
      def M.update(m : M.Msg) : Int do case m do M.Msg.#{msg} -> 1 end end
      def M.view(m : M.Msg) : Int do case m do M.Msg.#{msg} -> 2 end end
      """
    end

    {u, {:promoted, _}} = stage(Universe.new(), "base", patch(counter.("V1")))
    {u, v} = stage(u, "p2", patch(counter.("V2")))
    assert v == {:promoted, ["p2"]}
    assert Universe.committed(u)["M.Msg"].decl == decl("deftype M.Msg do V2 end")
  end

  # Neither promotes alone, so the two promote as one round.
  test "cascade: a later patch unblocks an earlier one" do
    {u, _} =
      stage(
        Universe.new(),
        "base",
        patch("def M.a() : Int do 1 end\ndef M.b() : Int do M.a() + 1 end")
      )

    {u, {:staged, _}} = stage(u, "p2", patch("def M.a() : String do \"two\" end"))
    {u, v} = stage(u, "p3", patch("def M.b() : String do M.a() ++ \"!\" end"))
    assert v == {:promoted, ["p2", "p3"]}
    assert Universe.committed(u)["M.a"].decl == decl("def M.a() : String do \"two\" end")
    assert rounds(u) == [["base"], ["p2", "p3"]]
  end

  test "mutually dependent patches promote together via scc grouping" do
    {u, {:staged, _}} = stage(Universe.new(), "pa", patch("def M.a() : Int do M.b() end"))
    {u, v} = stage(u, "pb", patch("def M.b() : Int do M.a() end"))
    assert v == {:promoted, ["pa", "pb"]}
    assert rounds(u) == [["pa", "pb"]]
  end

  test "removing an unreferenced symbol promotes" do
    {u, _} = stage(Universe.new(), "base", patch("def M.a() : Int do 1 end"))
    {u, v} = stage(u, "p2", [gone("M.a")])
    assert v == {:promoted, ["p2"]}
    assert Universe.committed(u) == %{}
    assert Enum.at(Universe.history(u), 1) == %{ids: ["p2"], entries: [{:gone, "M.a"}]}
  end

  test "removing a depended on symbol stays staged, then promotes with the dependent's removal" do
    {u, _} =
      stage(
        Universe.new(),
        "base",
        patch("def M.a() : Int do 1 end\ndef M.b() : Int do M.a() + 1 end")
      )

    {u, {:staged, why}} = stage(u, "p2", [gone("M.a")])
    sole(why, "M.b", "unbound")
    {u, v} = stage(u, "p3", [gone("M.b")])
    assert v == {:promoted, ["p2", "p3"]}
    assert Universe.committed(u) == %{}
    assert Enum.at(Universe.history(u), 1).entries == [{:gone, "M.a"}, {:gone, "M.b"}]
  end

  test "two tombstone only patches promote together (empty universe)" do
    {u, _} =
      stage(
        Universe.new(),
        "base",
        patch("def M.a() : Int do M.b() end\ndef M.b() : Int do M.a() end")
      )

    {u, {:staged, _}} = stage(u, "delA", [gone("M.a")])
    {u, v} = stage(u, "delB", [gone("M.b")])
    assert v == {:promoted, ["delA", "delB"]}
    assert Universe.committed(u) == %{}
  end

  # By the spec there is nothing to promote after dropping a patch: every set
  # without it could not promote before either. `good` promoted when staged.
  test "dropping a staged patch re-runs promotion and can unblock others" do
    {u, _} = stage(Universe.new(), "base", patch("def M.a() : Int do 1 end"))
    {u, {:promoted, _}} = stage(u, "good", patch("def M.b() : Int do M.a() end"))
    {u, {:staged, _}} = stage(u, "broken", patch("def M.b() : Int do M.a() ++ \"9\" end"))
    history = Universe.history(u)
    {u, true} = Universe.unstage(u, "broken")
    assert Universe.staged(u) == %{}
    assert Universe.committed(u)["M.b"].decl == decl("def M.b() : Int do M.a() end")
    assert Universe.history(u) == history
  end

  test "staged contents exposes defines and tombstones" do
    p = patch("def M.b() : Int do M.a() end") ++ [gone("M.z")]
    {u, {:staged, _}} = stage(Universe.new(), "p", p)
    assert Universe.staged(u)["p"] == p
  end

  test "promoting a new signature cannot leave a committed dependent broken" do
    {u, _} = stage(Universe.new(), "p1", patch("def M.a() : Int do 1 end"))
    {u, _} = stage(u, "p2", patch("def M.b() : Int do M.a() + 1 end"))
    assert names(u) == ["M.a", "M.b"]
    {u, {:staged, why}} = stage(u, "p3", patch("def M.a() : String do \"two\" end"))
    sole(why, "M.b", "mismatch")
    assert Universe.committed(u)["M.a"].decl == decl("def M.a() : Int do 1 end")
    assert NaiveUniverse.reasons(Universe.committed(u), []) == []
  end

  test "committed is always dependency consistent after arbitrary op sequences" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..200 do
      ops = for _ <- 1..UniverseCases.int(1, 26), do: UniverseCases.ts_op()

      u =
        ops
        |> Enum.with_index()
        |> Enum.reduce(Universe.new(), fn {op, i}, u ->
          u |> stage("p#{i}", entries([op])) |> elem(0)
        end)

      assert NaiveUniverse.reasons(Universe.committed(u), []) == [], inspect(ops)
    end
  end

  test "staged has a reason: anything left staged cannot promote alone" do
    {u, _} =
      stage(
        Universe.new(),
        "base",
        patch("def M.a() : Int do 1 end\ndef M.b() : Int do M.a() + 1 end")
      )

    {u, _} = stage(u, "p2", patch("def M.a() : String do \"two\" end"))
    ids = Map.keys(Universe.staged(u))
    assert ids != []
    assert Enum.all?(ids, &(Universe.reasons(u, &1) != []))
  end

  # ---------- Review Focus ----------

  test "the same name twice in one patch is a reason, committed unchanged" do
    u = Universe.new()
    src = "def A.f() : Int do\n  1\nend\n\ndef A.f() : Int do\n  2\nend"
    {u2, {:staged, [%{code: "duplicate"} | _]}} = Universe.stage(u, "p", patch(src))
    assert Universe.committed(u2) == Universe.committed(u)
  end

  test "empty id is refused and stages nothing" do
    {u, {:staged, [%{code: "bad-id"}]}} =
      Universe.stage(Universe.new(), "", patch("def A.f() : Int do\n  1\nend"))

    assert Universe.staged(u) == %{}
  end

  test "unstaging an unknown id is a no-op" do
    u = Universe.new()
    assert {^u, false} = Universe.unstage(u, "nope")
  end

  # The brief expected no new round here. The spec (`settle`) and Rust
  # promote a patch that changes nothing like any other: one round, so
  # history stays the record of every promotion. Pinned as Rust behaves;
  # see the task report.
  test "restaging an id with identical source promotes it as a round of its own" do
    {u, {:promoted, ["p"]}} =
      Universe.stage(Universe.new(), "p", patch("def A.f() : Int do\n  1\nend"))

    {u2, v} = Universe.stage(u, "p", patch("def A.f() : Int do\n  1\nend"))
    assert v == {:promoted, ["p"]}
    assert length(Universe.history(u2)) == length(Universe.history(u)) + 1
    assert Universe.committed(u2) == Universe.committed(u)
  end

  # ---------- the search against trying every subset ----------

  # What history promises across one operation: it only grows, by one entry
  # per round of the patches a stage promoted, and replaying it gives the
  # committed code.
  defp history_holds(before, verdict, after_u) do
    {old, new} = {Universe.history(before), Universe.history(after_u)}

    cond do
      Enum.take(new, length(old)) != old ->
        {:error, "history rewrote its past"}

      Enum.flat_map(Enum.drop(new, length(old)), & &1.ids) != promoted_ids(verdict) ->
        {:error, "history's new rounds are not what the stage promoted"}

      Universe.replay(new) != Map.new(Universe.committed(after_u), fn {n, c} -> {n, c.cid} end) ->
        {:error, "committed code is not what history replays to"}

      true ->
        :ok
    end
  end

  defp promoted_ids({:promoted, ids}), do: ids
  defp promoted_ids(_), do: []

  # Play a case on the universe and on the reference side by side. After
  # every operation they agree (verdicts, every staged patch's reasons,
  # committed code with each declaration's check, history), history holds,
  # nothing staged could still promote, and committed code typechecks.
  defp agrees_with_trying_every_subset(base, ops) do
    {naive, _} = NaiveUniverse.stage(NaiveUniverse.new(), "base", patch(Enum.join(base, "\n")))

    {_, {_, failure}} =
      play(base, ops, {naive, nil}, fn before, op, verdict, fast, {naive, failure} ->
        {naive, reference} = run(NaiveUniverse, naive, op)

        failure =
          failure ||
            begin_failure(op, before, verdict, reference, fast, naive)

        {naive, failure}
      end)

    if failure, do: flunk(failure)
  end

  defp begin_failure(op, before, verdict, reference, fast, naive) do
    history = history_holds(before, verdict, fast)
    left = NaiveUniverse.every_promotable(fast)
    broken = NaiveUniverse.reasons(Universe.committed(fast), [])

    why =
      for id <- Enum.sort(Map.keys(Universe.staged(fast))),
          mine = Universe.reasons(fast, id),
          theirs =
            NaiveUniverse.reasons(
              Universe.committed(naive),
              Map.get(Universe.staged(naive), id, [])
            ),
          mine != theirs,
          do: {id, mine, theirs}

    differ =
      verdict != reference or Universe.committed(fast) != Universe.committed(naive) or
        Universe.staged(fast) != Universe.staged(naive) or
        Universe.history(fast) != Universe.history(naive) or why != []

    if differ or history != :ok or left != [] or broken != [] do
      "after #{inspect(op)}: fast #{inspect(verdict)}, naive #{inspect(reference)}, history #{inspect(history)}, " <>
        "left promotable #{inspect(left)}, committed broken #{inspect(broken)}, reasons differ #{inspect(why)}, " <>
        "committed differ #{Universe.committed(fast) != Universe.committed(naive)}"
    end
  end

  @tag timeout: 600_000
  test "search equals the naive every-subset search" do
    :rand.seed(:exsss, {7, 7, 7})

    for _ <- 1..200 do
      {base, ops} = UniverseCases.random_case()
      agrees_with_trying_every_subset(base, ops)
    end
  end

  @tag timeout: 600_000
  test "the search promotes what trying every subset promotes, through types" do
    :rand.seed(:exsss, {8, 8, 8})

    for _ <- 1..200 do
      {base, ops} = UniverseCases.typed_case()
      agrees_with_trying_every_subset(base, ops)
    end
  end

  # Whether an operation promoted a round of two or more patches that
  # removed a name committed before it.
  defp removed_jointly(before, after_u) do
    committed = before.committed

    Universe.history(after_u)
    |> Enum.drop(length(Universe.history(before)))
    |> Enum.any?(fn r ->
      length(r.ids) >= 2 and
        Enum.any?(r.entries, fn e -> match?({:gone, n} when is_map_key(committed, n), e) end)
    end)
  end

  defp removes_committed(%{committed: committed}, {:stage, _, changes}),
    do: Enum.any?(changes, fn c -> match?({:gone, n} when is_map_key(committed, n), c) end)

  defp removes_committed(_, _), do: false

  defp removed(before, after_u),
    do: Enum.any?(Map.keys(before.committed), &(not Map.has_key?(after_u.committed, &1)))

  # Whether an operation promoted, in one round with a patch that changes
  # `T.A`, a patch that makes `T.C` nest `T.B`, while committed `T.g` does
  # not consult `T.A`.
  defp enabled_through_a_context(before, after_u) do
    reaches =
      case before.committed do
        %{"T.g" => g} -> not MapSet.member?(g.deps, "T.A")
        _ -> false
      end

    both = fn r ->
      Enum.all?(["T.A", "T.C"], fn n -> Enum.any?(r.entries, &match?({:live, ^n, _}, &1)) end)
    end

    reaches and
      Universe.history(after_u)
      |> Enum.drop(length(Universe.history(before)))
      |> Enum.any?(&(length(&1.ids) >= 2 and both.(&1)))
  end

  defp bump(seen, key, true), do: Map.update(seen, key, 1, &(&1 + 1))
  defp bump(seen, _key, false), do: seen

  # As the shapes test below, for the cases through types: changes are
  # refused through each kind of dependency, some promote together, and
  # tombstones both remove committed names and are refused. Rust plays 1,000
  # cases; this plays 200, so its floors are a fifth of Rust's.
  @tag timeout: 600_000
  test "the typed cases reach every dependency through types" do
    :rand.seed(:exsss, {9, 9, 9})

    kinds = [
      {"map key", "non-data-map-key", nil},
      {"case", "non-exhaustive", nil},
      {"field", "mismatch", "T.h"}
    ]

    seen =
      Enum.reduce(1..200, %{}, fn _, seen ->
        {base, ops} = UniverseCases.typed_case()

        {_, seen} =
          play(base, ops, seen, fn before, op, verdict, after_u, seen ->
            case verdict do
              {:promoted, ids} ->
                seen
                |> bump("together", length(ids) >= 2)
                |> bump("enabled through a context", enabled_through_a_context(before, after_u))
                |> bump("removed", removed(before, after_u))
                |> bump("removed jointly", removed_jointly(before, after_u))

              {:staged, reasons} ->
                Enum.reduce(kinds, seen, fn {kind, code, name}, seen ->
                  bump(
                    seen,
                    kind,
                    Enum.any?(reasons, &(&1.code == code and (name == nil or &1.name == name)))
                  )
                end)
                |> bump("removal refused", removes_committed(before, op))

              nil ->
                seen
            end
          end)

        seen
      end)

    enough = fn k, n -> Map.get(seen, k, 0) >= n end

    assert Enum.all?(["map key", "case", "field"], &enough.(&1, 60)) and enough.("together", 16) and
             enough.("enabled through a context", 2) and enough.("removed", 20) and
             enough.("removed jointly", 4) and enough.("removal refused", 20),
           inspect(seen)
  end

  # The property above is only as strong as the cases it sees. These are the
  # shapes the search's mechanisms exist for; if the generator stops
  # reaching them, this fails before the property quietly weakens. Rust
  # plays 2,000 cases; this plays 200, so its floors are a tenth of Rust's.
  @tag timeout: 600_000
  test "the generated cases reach the shapes that matter" do
    :rand.seed(:exsss, {10, 10, 10})

    counts =
      Enum.reduce(1..200, %{}, fn _, counts ->
        {base, ops} = UniverseCases.random_case()

        {_, counts} =
          play(base, ops, counts, fn
            before, {:stage, i, changes} = op, verdict, after_u, counts ->
              probe = Universe.put(before, "p#{i}", entries(changes))
              {links, _} = Search.links(probe, MapSet.new())
              {graph, parts} = Search.parts("p#{i}", links)
              promoted = length(promoted_ids(verdict))

              counts
              |> bump(
                :joint,
                Enum.any?(links, fn {_, l} -> MapSet.size(l) >= 3 end) and map_size(graph) >= 3
              )
              |> bump(:split, length(parts) >= 2)
              |> bump(:split_promoted, length(parts) >= 2 and promoted > 0)
              |> bump(:three, promoted >= 3)
              |> bump(:removed, removed(before, after_u))
              |> bump(:removal_refused, promoted == 0 and removes_committed(before, op))
              |> bump(:removed_together, removed_jointly(before, after_u))

            _, _, _, _, counts ->
              counts
          end)

        counts
      end)

    floors = [
      joint: 300,
      split: 40,
      split_promoted: 15,
      three: 15,
      removed: 30,
      removed_together: 8,
      removal_refused: 30
    ]

    assert Enum.all?(floors, fn {k, n} -> Map.get(counts, k, 0) >= n end), inspect(counts)
  end

  test "replay builds what the rounds commit" do
    rounds = [
      %{ids: ["a"], entries: [{:live, "M.a", "1"}, {:live, "M.b", "2"}]},
      %{ids: ["b"], entries: [{:gone, "M.a"}, {:live, "M.b", "3"}]}
    ]

    assert Universe.replay(rounds) == %{"M.b" => "3"}
  end

  # A universe built before an upgrade holds a stale copy of the stdlib (or
  # none of it): it still checks against the stdlib as it is now.
  test "a universe whose table lacks a stdlib row reads the live stdlib" do
    stale = %{Universe.new() | sigs: Map.delete(Stdlib.signatures(), "Map.size")}

    assert {:ok, _, {:named, "Int"}} = Kinoko.Lang.check_expr(stale, "Map.size(%{1 => 2})")
    assert Universe.signatures(stale)["Map.size"] == Stdlib.signature("Map.size")
    assert Universe.signatures(Universe.new()) == Stdlib.signatures()
  end
end
