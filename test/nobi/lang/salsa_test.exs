defmodule Nobi.Lang.SalsaTest do
  @moduledoc """
  Port of `crates/nobi/tests/salsa.rs`: one test per Rust test, same names,
  then the model test (salsa equals evaluating from scratch) over seeded
  `:rand` cases in place of proptest. `stats.computes` stands in for the
  Rust tests' logging closure.
  """
  use ExUnit.Case, async: true

  alias Nobi.Lang.Salsa
  alias Nobi.Lang.SalsaGraph
  alias Nobi.Lang.SalsaQueries

  @committed ["committed"]
  @overlay ["staging", "committed"]
  @depth 256

  defp db, do: Salsa.new(SalsaQueries)

  defp runs(db, q), do: Map.get(Salsa.stats(db).computes, q, 0)

  defp total_runs(db),
    do: db |> Salsa.stats() |> Map.fetch!(:computes) |> Map.values() |> Enum.sum()

  defp counts(db), do: {Salsa.stats(db).queries, Salsa.stats(db).memos}

  # ---------- memoization ----------

  test "second identical query does not re-run" do
    db = Salsa.set(db(), "committed", "A", "a1")
    assert {{:ok, "a1"}, db} = Salsa.query(db, @committed, {:check, "A"})
    assert {{:ok, "a1"}, db} = Salsa.query(db, @committed, {:check, "A"})
    assert runs(db, {:check, "A"}) == 1
  end

  test "input change invalidates dependents" do
    db = Salsa.set(db(), "committed", "A", "a1")
    assert {{:ok, "a1"}, db} = Salsa.query(db, @committed, {:check, "A"})
    db = Salsa.set(db, "committed", "A", "x9")
    assert {{:ok, "x9"}, db} = Salsa.query(db, @committed, {:check, "A"})
    assert runs(db, {:check, "A"}) == 2
  end

  # ---------- early cutoff ----------

  test "body edit with unchanged signature never recomputes dependents" do
    db = db() |> Salsa.set("committed", "A", "a1") |> Salsa.set("committed", "B", "b1|A")
    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @committed, {:check, "B"})
    # A body edit: the source changes, the signature (first character) does not.
    db = Salsa.set(db, "committed", "A", "a2")
    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @committed, {:check, "B"})
    # Sig A ran again (its input changed); Check B was cut off.
    assert {runs(db, {:sig, "A"}), runs(db, {:check, "B"})} == {2, 1}
    # An edit that changes the signature does reach it.
    db = Salsa.set(db, "committed", "A", "z3")
    assert {{:ok, "b1+z"}, db} = Salsa.query(db, @committed, {:check, "B"})
    assert runs(db, {:check, "B"}) == 2
  end

  # ---------- layer overlay ----------

  test "staging shadows committed per context" do
    db = db() |> Salsa.set("committed", "A", "a1") |> Salsa.set("staging", "A", "s1")
    assert {{:ok, "s1"}, db} = Salsa.query(db, @overlay, {:check, "A"})
    assert {{:ok, "a1"}, _} = Salsa.query(db, @committed, {:check, "A"})
  end

  test "tombstone in staging hides a committed input" do
    db = db() |> Salsa.set("committed", "A", "a1") |> Salsa.set("staging", "A", :tombstone)
    assert {{:error, "no source for A"}, db} = Salsa.query(db, @overlay, {:check, "A"})
    assert {{:ok, "a1"}, _} = Salsa.query(db, @committed, {:check, "A"})
  end

  test "staging gaining a key invalidates overlay results that fell through" do
    db = Salsa.set(db(), "committed", "A", "a1")
    assert {{:ok, "a1"}, db} = Salsa.query(db, @overlay, {:check, "A"})
    db = Salsa.set(db, "staging", "A", "s1")
    assert {{:ok, "s1"}, _} = Salsa.query(db, @overlay, {:check, "A"})
  end

  test "memo entries are per context: overlay result never leaks into committed" do
    db = db() |> Salsa.set("committed", "A", "a1") |> Salsa.set("staging", "A", "s1")
    assert {{:ok, "s1"}, db} = Salsa.query(db, @overlay, {:check, "A"})
    assert {{:ok, "a1"}, db} = Salsa.query(db, @committed, {:check, "A"})
    assert {{:ok, "s1"}, db} = Salsa.query(db, @overlay, {:check, "A"})
    # One per context, each memoized.
    assert runs(db, {:check, "A"}) == 2
  end

  # ---------- context-free queries ----------

  test "content-keyed queries compute once across contexts" do
    assert {{:ok, "ast-of-abc"}, db} = Salsa.query(db(), @overlay, {:parse, "abc"})
    assert {{:ok, "ast-of-abc"}, db} = Salsa.query(db, @committed, {:parse, "abc"})
    assert total_runs(db) == 1
  end

  # ---------- review regressions ----------

  test "memo keys do not collide across arg or context boundaries" do
    assert {{:ok, "a,b"}, db} = Salsa.query(db(), ["c"], {:echo, ["a,b"]})
    assert {{:ok, "a|b"}, db} = Salsa.query(db, ["c"], {:echo, ["a", "b"]})
    # The contexts read differently, so a shared memo would show.
    db = db |> Salsa.set("a+b", "X", "x1") |> Salsa.set("a", "X", "x2")
    assert {{:ok, "x1"}, db} = Salsa.query(db, ["a+b"], {:check, "X"})
    assert {{:ok, "x2"}, _} = Salsa.query(db, ["a", "b"], {:check, "X"})
  end

  # Rust: an input set as an `Arc` the caller keeps cannot be mutated through
  # it. In Elixir values are immutable; rebinding the caller's copy changes
  # nothing the db holds.
  test "mutating a stored input object does not bypass the revision counter" do
    held = "a1"
    db = Salsa.set(db(), "committed", "A", held)
    assert {{:ok, "a1"}, db} = Salsa.query(db, @committed, {:check, "A"})
    held = held <> "x9"
    assert held == "a1x9"
    assert {{:ok, "a1"}, _} = Salsa.query(db, @committed, {:check, "A"})
  end

  test "mutating a query result does not corrupt the memo" do
    db = Salsa.set(db(), "committed", "K", "1")
    {first, db} = Salsa.query(db, @committed, {:check, "K"})
    first = put_elem(first, 1, "999")
    assert first == {:ok, "999"}
    assert {{:ok, "1"}, _} = Salsa.query(db, @committed, {:check, "K"})
  end

  # ---------- robustness ----------

  test "query cycles are an error, not a hang" do
    assert {{:error, {:cycle, :loop}}, _} = Salsa.query(db(), @committed, :loop)
  end

  # ---------- what Rust adds ----------

  test "rust_only: the revision moves only when an input changes" do
    db = Salsa.set(db(), "committed", "A", "a1")
    before = Salsa.revision(db)
    db = db |> Salsa.set("committed", "A", "a1") |> Salsa.unset("staging", "A")
    assert Salsa.revision(db) == before
    db = Salsa.set(db, "staging", "A", :tombstone)
    assert Salsa.revision(db) > before
  end

  test "rust_only: unset lets the layers below show through" do
    db = db() |> Salsa.set("committed", "A", "a1") |> Salsa.set("staging", "A", "s1")
    assert {{:ok, "s1"}, db} = Salsa.query(db, @overlay, {:check, "A"})
    db = Salsa.unset(db, "staging", "A")
    assert {{:ok, "a1"}, _} = Salsa.query(db, @overlay, {:check, "A"})
  end

  # A memo serves another context (a trial) where every read gives what it
  # gave: a body edit of A keeps its signature, so B's check runs once for
  # both contexts, and a signature edit runs it again.
  test "rust_only: a memo serves every context whose reads agree" do
    db =
      db()
      |> Salsa.set("committed", "A", "a1")
      |> Salsa.set("committed", "B", "b1|A")
      |> Salsa.set("staging", "A", "a2")

    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @committed, {:check, "B"})
    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @overlay, {:check, "B"})
    assert {runs(db, {:sig, "A"}), runs(db, {:check, "B"})} == {2, 1}
    db = Salsa.set(db, "staging", "A", "z2")
    assert {{:ok, "b1+z"}, db} = Salsa.query(db, @overlay, {:check, "B"})
    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @committed, {:check, "B"})
    assert runs(db, {:check, "B"}) == 2
  end

  # Committed code where D reads A, B, C and E, each of signature `c`; and a
  # patch per entry of `patches`: a layer, the name it changes, and that
  # name's signature there.
  defp universe(patches) do
    db = Salsa.set(db(), "committed", "D", "d|A,B,C,E")
    db = Enum.reduce(~w(A B C E), db, &Salsa.set(&2, "committed", &1, "c1"))

    Enum.reduce(patches, db, fn {layer, name, sig}, db ->
      Salsa.set(db, layer, name, sig <> "1")
    end)
  end

  # A universe's search: D checked in every trial, each subset of `patches`,
  # in bitmask order, so the ways D can read interleave.
  defp search(db, patches) do
    n = length(patches)

    Enum.reduce(0..(Bitwise.bsl(1, n) - 1), db, fn trial, db ->
      on =
        for {p, i} <- Enum.with_index(patches), Bitwise.band(trial, Bitwise.bsl(1, i)) != 0, do: p

      ctx = Enum.map(on, &elem(&1, 0)) ++ ["committed"]

      sig = fn name ->
        Enum.find_value(on, "c", fn {_, n, s} -> if n == name, do: s end)
      end

      want = "d" <> Enum.map_join(~w(A B C E), &("+" <> sig.(&1)))
      assert {{:ok, ^want}, db} = Salsa.query(db, ctx, {:check, "D"})
      db
    end)
  end

  # Three patches change signatures D reads, three change none: 64 trials, 8
  # ways for D to read, more than the versions kept. Each is checked once,
  # and after an unrelated change, a second search checks none again.
  test "rust_only: a search checks each way of reading once" do
    patches = [
      {"pA", "A", "f"},
      {"pB", "B", "g"},
      {"pC", "C", "h"},
      {"pX", "X", "x"},
      {"pY", "Y", "y"},
      {"pZ", "Z", "z"}
    ]

    db = patches |> universe() |> search(patches)
    assert runs(db, {:check, "D"}) == 8
    db = db |> Salsa.set("committed", "Q", "q1") |> search(patches)
    assert runs(db, {:check, "D"}) == 8
  end

  # After a change, a search keeps the memos it reused before its first new
  # check: they too were used at this revision. Four patches give D 16 ways
  # to read; E's patch changes, reaching 8 of them, and a fifth patch, which
  # D does not read, brings every way back once more.
  test "rust_only: a search after a change keeps what it reused" do
    patches = [
      {"pA", "A", "f"},
      {"pB", "B", "g"},
      {"pC", "C", "h"},
      {"pE", "E", "i"},
      {"pX", "X", "x"}
    ]

    db = patches |> universe() |> search(patches)
    assert runs(db, {:check, "D"}) == 16
    patches = List.replace_at(patches, 3, {"pE", "E", "j"})
    db = db |> Salsa.set("pE", "E", "j1") |> search(patches)
    assert runs(db, {:check, "D"}) == 24
  end

  # A body that ignores the error still fails: its value would depend on who
  # asked, not only on what it read.
  test "rust_only: a body that ignores a cycle still fails" do
    assert {{:error, {:cycle, :loop_quietly}}, _} = Salsa.query(db(), @committed, :loop_quietly)
  end

  # Past the depth limit, an error and not a crash, whatever the memo holds:
  # a chain built up one query at a time nests as deep when asked.
  test "rust_only: queries nested past the depth limit are an error, not a crash" do
    assert {{:ok, "end"}, _} = Salsa.query(db(), @committed, {:chain, @depth - 1})
    assert {{:error, :too_deep}, _} = Salsa.query(db(), @committed, {:chain, @depth})

    db =
      Enum.reduce(0..(@depth - 1), db(), fn n, db ->
        assert {{:ok, "end"}, db} = Salsa.query(db, @committed, {:chain, n})
        db
      end)

    assert {{:error, :too_deep}, _} = Salsa.query(db, @committed, {:chain, @depth})
  end

  test "rust_only: depth is an option" do
    db = Salsa.new(SalsaQueries, depth: 3)
    assert {{:ok, "end"}, _} = Salsa.query(db, @committed, {:chain, 2})
    assert {{:error, :too_deep}, _} = Salsa.query(db, @committed, {:chain, 3})
  end

  test "rust_only: retain forgets what it rejects" do
    db = Salsa.set(db(), "committed", "A", "a1")

    db =
      Enum.reduce(1..2, db, fn _, db ->
        assert {{:ok, "a1"}, db} = Salsa.query(db, @committed, {:check, "A"})
        assert {{:ok, "a"}, db} = Salsa.query(db, @committed, {:sig, "A"})
        Salsa.retain(db, &(&1 != {:check, "A"}))
      end)

    # Dropping {:check, "A"}'s last memo drops its count too (`stats`);
    # the running per-tag counter keeps every run.
    assert {runs(db, {:check, "A"}), runs(db, {:sig, "A"})} == {0, 1}
    assert {Salsa.computed(db, :check), Salsa.computed(db, :sig)} == {2, 1}
  end

  # Sig A has a memo that read `a1` and one that read `a2`. Dropping what read
  # `a1` drops the first alone: Check B read Sig A's value, never `a1`, so its
  # memo stays, and so do those that read a tombstone or nothing.
  test "rust_only: retain_reads forgets every memo that read what it rejects" do
    db =
      db()
      |> Salsa.set("committed", "A", "a1")
      |> Salsa.set("committed", "B", "b1|A")
      |> Salsa.set("staging", "A", "a2")
      |> Salsa.set("staging", "C", :tombstone)

    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @committed, {:check, "B"})
    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @overlay, {:check, "B"})
    assert {{:error, "no source for C"}, db} = Salsa.query(db, @overlay, {:check, "C"})
    assert {{:ok, "x"}, db} = Salsa.query(db, @committed, {:echo, ["x"]})
    {queries, memos} = counts(db)
    db = Salsa.retain_reads(db, &(&1 != "a1"))
    assert counts(db) == {queries, memos - 1}
    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @committed, {:check, "B"})
    assert {{:error, "no source for C"}, db} = Salsa.query(db, @overlay, {:check, "C"})
    assert {{:ok, "x"}, db} = Salsa.query(db, @committed, {:echo, ["x"]})
    # Sig A again, in committed: the overlay's memo read `a2`.
    assert Enum.map([{:check, "B"}, {:sig, "A"}, {:check, "C"}, {:echo, ["x"]}], &runs(db, &1)) ==
             [1, 3, 1, 1]

    db = Salsa.retain_reads(db, &(&1 != "a1" and &1 != "a2"))
    assert counts(db) == {queries - 1, memos - 2}
  end

  # `staging` no longer holds A, so the memo Sig A kept for the overlay goes
  # (it read `x2`), and Check B's memo for the overlay is left reading what no
  # memo gives: `trim` drops it, and keeps the one every memo it read still
  # gives. A query that holds no memo is let be.
  test "rust_only: trim forgets every memo that read what no memo gives" do
    db =
      db()
      |> Salsa.set("committed", "A", "a1")
      |> Salsa.set("committed", "B", "b1|A")
      |> Salsa.set("staging", "A", "x2")

    assert {{:ok, "b1+x"}, db} = Salsa.query(db, @overlay, {:check, "B"})
    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @committed, {:check, "B"})
    db = db |> Salsa.unset("staging", "A") |> Salsa.retain_reads(&(&1 != "x2"))
    assert Salsa.stats(db).memos == 3
    db = Salsa.trim(db)
    assert Salsa.stats(db).memos == 2
    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @committed, {:check, "B"})
    assert runs(db, {:check, "B"}) == 2
    db = db |> Salsa.retain(&(&1 != {:sig, "A"})) |> Salsa.trim()
    assert Salsa.stats(db).memos == 1
    assert {{:ok, "b1+a"}, db} = Salsa.query(db, @committed, {:check, "B"})
    # {:sig, "A"}'s count went with its memos; the per-tag counter keeps all three runs.
    assert {runs(db, {:check, "B"}), runs(db, {:sig, "A"})} == {2, 1}
    assert {Salsa.computed(db, :check), Salsa.computed(db, :sig)} == {2, 3}
  end

  test "computes are pruned with their query's memos; computed/2 keeps counting" do
    db =
      Enum.reduce(1..50, db(), fn i, db ->
        db = Salsa.set(db, "committed", "A#{i}", "a")
        {{:ok, _}, db} = Salsa.query(db, @committed, {:check, "A#{i}"})
        db |> Salsa.unset("committed", "A#{i}") |> Salsa.retain(&(&1 != {:check, "A#{i}"}))
      end)

    assert map_size(Salsa.stats(db).computes) == 0
    assert Salsa.computed(db, :check) == 50
    assert Salsa.computed(db, :nothing) == 0
  end

  # Dropping a memo can leave what read it reading what no memo gives: `trim`
  # goes on until none is. Here three queries, each asking the one before,
  # the first reading an input that layer 1 no longer holds.
  test "rust_only: trim follows what read what it drops" do
    steps = [[{:input, 0}], [{:query, 0}], [{:query, 1}]]

    db =
      SalsaGraph
      |> Salsa.new(env: steps)
      |> Salsa.set(0, 0, 1)
      |> Salsa.set(1, 0, 2)

    assert {{:ok, 3}, db} = Salsa.query(db, [1, 0], 2)
    assert {{:ok, 2}, db} = Salsa.query(db, [0], 2)
    db = db |> Salsa.unset(1, 0) |> Salsa.retain_reads(&(&1 != 2))
    assert Salsa.stats(db).memos == 5
    db = Salsa.trim(db)
    assert Salsa.stats(db).memos == 3
    before = Salsa.stats(db).computes
    assert {{:ok, 2}, db} = Salsa.query(db, [0], 2)
    assert Salsa.stats(db).computes == before
  end

  test "stats count queries, memos and reads" do
    db = db() |> Salsa.set("committed", "A", "a1") |> Salsa.set("committed", "B", "b1|A")
    assert Salsa.stats(db) == %{queries: 0, memos: 0, reads: 0, computes: %{}}
    {_, db} = Salsa.query(db, @committed, {:check, "B"})
    # Check B read input B and Sig A; Sig A read input A.
    assert Salsa.stats(db) == %{
             queries: 2,
             memos: 2,
             reads: 3,
             computes: %{{:check, "B"} => 1, {:sig, "A"} => 1}
           }
  end

  # ---------- salsa equals evaluating from scratch ----------

  @keys 4
  @layers 3
  @queries 5
  @cases 500

  # 0..n-1
  defp below(n), do: :rand.uniform(n) - 1

  defp gen_step(0), do: {:input, below(@keys)}

  defp gen_step(refs) do
    case below(4) do
      0 -> {:input, below(@keys)}
      1 -> {:query, below(refs)}
      2 -> {:branch, below(@keys), below(refs), below(refs)}
      3 -> {:ignore, below(refs)}
    end
  end

  defp gen_op do
    # Weights 3 : 1 : 4 : 1 : 1, as the Rust strategy.
    case below(10) do
      n when n < 3 ->
        {:set, below(@layers), below(@keys), if(below(2) == 0, do: :tombstone, else: below(4))}

      3 ->
        {:unset, below(@layers), below(@keys)}

      n when n < 8 ->
        ctx = Enum.take(Enum.shuffle(Enum.to_list(0..(@layers - 1))), below(@layers + 1))
        {:ask, ctx, below(@queries)}

      8 ->
        {:forget, below(@queries)}

      9 ->
        :trim
    end
  end

  # A random graph, and edits and asks over it in random contexts. Without
  # cycles, query `i` asks only queries before it; with them, any query.
  defp gen_case(cycles) do
    steps =
      for i <- 0..(@queries - 1) do
        for _ <- 1..(1 + below(3)), do: gen_step(if cycles, do: @queries, else: i)
      end

    {steps, for(_ <- 1..(1 + below(39)), do: gen_op())}
  end

  # One entry per ask: what salsa gave, what evaluating from scratch gave,
  # and the queries salsa computed for it.
  defp play(steps, ops) do
    init = {Salsa.new(SalsaGraph, env: steps), %{}, []}

    {_, _, asked} =
      Enum.reduce(ops, init, fn
        {:set, l, k, v}, {db, layers, asked} ->
          {Salsa.set(db, l, k, v), Map.put(layers, {l, k}, if(v == :tombstone, do: nil, else: v)),
           asked}

        {:unset, l, k}, {db, layers, asked} ->
          {Salsa.unset(db, l, k), Map.delete(layers, {l, k}), asked}

        {:ask, ctx, q}, {db, layers, asked} ->
          before = Salsa.stats(db).computes
          {salsa, db} = Salsa.query(db, ctx, q)
          fresh = SalsaGraph.fresh(steps, layers, ctx, q)

          computed =
            for {cq, n} <- Salsa.stats(db).computes, n > Map.get(before, cq, 0), do: cq

          a = %{ctx: ctx, query: q, salsa: salsa, fresh: fresh, computed: computed}
          {db, layers, [a | asked]}

        {:forget, q}, {db, layers, asked} ->
          {Salsa.retain(db, &(&1 != q)), layers, asked}

        :trim, {db, layers, asked} ->
          {Salsa.trim(db), layers, asked}
      end)

    Enum.reverse(asked)
  end

  defp agrees(cycles) do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..@cases do
      {steps, ops} = gen_case(cycles)

      for a <- play(steps, ops) do
        assert a.salsa == a.fresh,
               "asking #{a.query} in #{inspect(a.ctx)}\nsteps: #{inspect(steps)}\nops: #{inspect(ops)}"
      end
    end
  end

  test "rust_only: salsa equals evaluating from scratch" do
    agrees(false)
  end

  # The same errors, where a query ignored one too.
  test "rust_only: salsa equals evaluating from scratch through cycles" do
    agrees(true)
  end

  # The properties above are only as strong as the cases they see. If the
  # generators stop reaching salsa's mechanisms, this fails before the
  # properties quietly weaken.
  test "rust_only: the generated cases reach every mechanism" do
    :rand.seed(:exsss, {1, 2, 3})

    zero = %{cut_off: 0, shared: 0, again: 0, failed: 0, answered: 0}

    counts =
      for cycles <- [false, true], _ <- 1..@cases, reduce: zero do
        acc ->
          {steps, ops} = gen_case(cycles)

          {acc, _} =
            Enum.reduce(play(steps, ops), {acc, %{}}, fn a, {acc, seen} ->
              contexts = Map.get(seen, a.query, [])
              computed = a.query in a.computed
              bump = &if(&2, do: Map.update!(&1, &3, fn n -> n + 1 end), else: &1)

              acc =
                acc
                # Something it reads was computed again, to an equal value.
                |> bump.(not cycles and a.computed != [] and not computed, :cut_off)
                # Its memo from another context served this one.
                |> bump.(
                  not cycles and contexts != [] and a.ctx not in contexts and not computed,
                  :shared
                )
                # Asked again in the same context, it was computed again.
                |> bump.(not cycles and a.ctx in contexts and computed, :again)
                # Through cycles, some asks fail and some answer.
                |> bump.(cycles and match?({:error, _}, a.salsa), :failed)
                |> bump.(cycles and match?({:ok, _}, a.salsa), :answered)

              {acc, Map.put(seen, a.query, [a.ctx | contexts])}
            end)

          acc
      end

    # About half of what a seeded run sees.
    assert counts.cut_off >= 70 and counts.shared >= 630 and counts.again >= 30 and
             counts.failed >= 1580 and counts.answered >= 400,
           inspect(counts)
  end
end
