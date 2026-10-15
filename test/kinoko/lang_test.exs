defmodule Kinoko.LangTest do
  use ExUnit.Case, async: true

  doctest Kinoko.Lang

  alias Kinoko.Lang
  alias Kinoko.Lang.Universe

  @counter File.read!("test/fixtures/yabu/counter.yabu")

  defp promoted do
    {u, {:promoted, ["counter"]}} = Lang.stage(Lang.new(), "counter", @counter)
    u
  end

  test "the counter corpus stages and promotes" do
    assert %{} = promoted() |> Lang.history() |> hd()
  end

  test "read returns canonical text, committed first, else staged" do
    u = promoted()
    {:ok, decls} = Lang.parse(@counter)
    update = Enum.find(decls, &(Kinoko.Lang.Ast.name(&1) == "Counter.update"))
    assert {:ok, text} = Lang.read(u, "Counter.update")
    assert text == Kinoko.Lang.Format.decl(update)
    assert Lang.read(u, "Nope") == :error

    {u, {:staged, _}} = Lang.stage(u, "p", "def Counter.zzz() : Int do\n  \"x\"\nend")
    assert {:ok, "def Counter.zzz" <> _} = Lang.read(u, "Counter.zzz")
  end

  test "symbols lists committed names with cid and signature" do
    syms = Lang.symbols(promoted())
    assert length(syms) == 6
    assert Enum.all?(syms, &(is_binary(&1.cid) and is_binary(&1.signature)))
    assert %{signature: sig} = Enum.find(syms, &(&1.name == "Counter.update"))
    assert sig =~ ~r/^Counter\.update\(.*\) : /
  end

  test "a parse error is a staged reason and leaves the universe unchanged" do
    u = promoted()
    assert {^u, {:staged, [%{code: "parse", message: msg}]}} = Lang.stage(u, "bad", "def (")
    assert msg =~ ~r/\d+:\d+/
    assert Lang.parse("def (") |> elem(0) == :error
  end

  test "remove promotes the removal of the app" do
    {u, verdict} = Lang.stage(promoted(), "rm", "", remove: ["Counter"])
    assert {:promoted, ["rm"]} = verdict
    refute Enum.any?(Lang.symbols(u), &(&1.name == "Counter"))
  end

  test "format and cid" do
    assert {:ok, text} = Lang.format(@counter)
    assert {:ok, ^text} = Lang.format(text)
    {:ok, [d | _]} = Lang.parse(@counter)
    assert Lang.cid(d) =~ ~r/^[0-9a-f]{64}$/
    assert {:ok, ^text} = Lang.format(elem(Lang.parse(@counter), 1))
  end

  test "unstage" do
    {u, _} = Lang.stage(Lang.new(), "x", "def A.f() : Int do\n  \"s\"\nend")
    assert {_, true} = Lang.unstage(u, "x")
  end

  describe "a parse error restaged under an id" do
    test "drops what the id staged before" do
      {u, {:staged, [%{code: "unbound"}]}} =
        Lang.stage(Lang.new(), "p1", "def A.f() : Int do\n  A.g()\nend")

      assert Map.has_key?(Universe.staged(u), "p1")

      {u, {:staged, [%{code: "parse", name: nil}]}} = Lang.stage(u, "p1", "def (")
      refute Map.has_key?(Universe.staged(u), "p1")

      # p2 would have unblocked the old p1: only p2 promotes.
      assert {u, {:promoted, ["p2"]}} = Lang.stage(u, "p2", "def A.g() : Int do\n  1\nend")
      assert Enum.map(Lang.symbols(u), & &1.name) == ["A.g"]
    end

    test "of an id that staged nothing leaves the universe as it was" do
      u = promoted()
      assert {^u, {:staged, [%{code: "parse"}]}} = Lang.stage(u, "nothing", "def (")
    end
  end

  describe "refused input" do
    test "an id that is not a string is a bad-id reason" do
      u = Lang.new()

      for id <- [nil, :p, 1, ~c"p"] do
        assert {^u, {:staged, [%{code: "bad-id", name: nil}]}} =
                 Lang.stage(u, id, "def A.f() : Int do\n  1\nend")
      end

      assert {^u, false} = Lang.unstage(u, :p)
    end

    test "a remove entry that is not a string is a bad-name reason" do
      u = promoted()

      for removes <- [[:Counter], ["Counter", 1], "Counter"] do
        assert {^u, {:staged, [%{code: "bad-name", message: message}]}} =
                 Lang.stage(u, "rm", "", remove: removes)

        assert message =~ "`remove:` lists names"
      end
    end

    test "source that is not a string is a parse reason" do
      u = Lang.new()
      assert {^u, {:staged, [%{code: "parse"}]}} = Lang.stage(u, "p", nil)
    end
  end

  describe "a fault of the universe" do
    # A universe whose database is not one: every operation on it raises.
    defp broken(u), do: %{u | salsa: :not_a_database}

    test "stage returns the universe given and an internal reason" do
      u = broken(Lang.new())

      assert {^u, {:staged, [%{name: nil, code: "internal", message: message}]}} =
               Lang.stage(u, "p", "def A.f() : Int do\n  1\nend")

      assert is_binary(message) and message != ""
    end

    test "unstage returns the universe given and an internal error" do
      {u, {:staged, _}} = Lang.stage(Lang.new(), "p", "def A.f() : Int do\n  A.g()\nend")
      u = broken(u)
      assert {^u, {:error, %{name: nil, code: "internal"}}} = Lang.unstage(u, "p")
    end
  end

  test "read prefers committed code, then the lowest staged id that defines the name" do
    u = promoted()
    {u, {:staged, _}} = Lang.stage(u, "b", "def Z.f() : Int do\n  \"b\"\nend")
    {u, {:staged, _}} = Lang.stage(u, "a", "def Z.f() : Int do\n  \"a\"\nend")
    {u, {:staged, _}} = Lang.stage(u, "0", "def Z.g() : Int do\n  \"0\"\nend", remove: ["Z.f"])
    assert {:ok, text} = Lang.read(u, "Z.f")
    assert text =~ ~s("a")

    {u, {:staged, _}} = Lang.stage(u, "c", "def Counter.update() : Int do\n  \"c\"\nend")
    {:ok, committed} = Lang.read(u, "Counter.update")
    refute committed =~ ~s("c")
  end

  test "staged gives each patch's source, removals and reasons" do
    u = promoted()

    {u, {:staged, reasons}} =
      Lang.stage(u, "p", "def Z.f() : Int do\n  Z.g()\nend", remove: ["Z.h"])

    assert %{"p" => %{source: source, removes: ["Z.h"], reasons: ^reasons}} = Lang.staged(u)
    assert {:ok, ^source} = Lang.format("def Z.f() : Int do\n  Z.g()\nend")
    assert reasons == Lang.reasons(u, "p")
    assert Lang.reasons(u, "none") == []
  end

  test "committed gives each name's typed tree and signature" do
    u = promoted()
    committed = Lang.committed(u)
    assert map_size(committed) == 6

    for {name, c} <- committed do
      assert %{cid: cid, decl: decl, typed: typed, deps: %MapSet{}, signature: sig} = c
      assert Lang.cid(decl) == cid
      assert sig == Lang.signatures(u)[name]
      assert typed != nil
    end

    assert {:def, [{:named, _} | _], _} = committed["Counter.update"].signature
  end

  # ---------- durable state, restore, prepare, snapshot ----------

  @cid ~r/\A[0-9a-f]{64}\z/

  # Every binary in `term`.
  defp binaries(term) when is_binary(term), do: [term]
  defp binaries(term) when is_list(term), do: Enum.flat_map(term, &binaries/1)
  defp binaries(term) when is_tuple(term), do: term |> Tuple.to_list() |> binaries()

  defp binaries(term) when is_map(term) and not is_struct(term),
    do: Enum.flat_map(term, fn {k, v} -> binaries(k) ++ binaries(v) end)

  defp binaries(term) when is_atom(term) or is_number(term), do: []

  # The atoms in `term`.
  defp atoms(term) when is_atom(term), do: [term]
  defp atoms(term) when is_list(term), do: Enum.flat_map(term, &atoms/1)
  defp atoms(term) when is_tuple(term), do: term |> Tuple.to_list() |> atoms()

  defp atoms(term) when is_map(term) and not is_struct(term),
    do: Enum.flat_map(term, fn {k, v} -> atoms(k) ++ atoms(v) end)

  defp atoms(_), do: []

  # What CodeDb does: each canonical text `prepare` gives, parsed back.
  defp decls_of(texts) do
    Map.new(texts, fn {cid, text} ->
      {:ok, [decl]} = Lang.parse(text)
      {cid, decl}
    end)
  end

  # Stage `source` as Universe will: prepare, then stage the entries; the
  # CAS rows accumulate in `cas`.
  defp staged_via_prepare({u, cas}, id, source, opts \\ []) do
    {:ok, entries, texts} = Lang.prepare(source, opts)
    {u, _verdict} = Lang.stage_entries(u, id, entries)
    {u, Map.merge(cas, Map.new(texts))}
  end

  # A universe with three commits (one a tombstone), a broken staged patch,
  # a staged removal, and an id restaged after another was staged.
  defp storied do
    {Lang.new(), %{}}
    |> staged_via_prepare(
      "base",
      "def M.a() : Int do\n  1\nend\n\ndef M.b() : Int do\n  M.a()\nend"
    )
    |> staged_via_prepare("edit", "def M.a() : Int do\n  2\nend")
    |> staged_via_prepare("drop", "def M.c() : Int do\n  M.a()\nend", remove: ["M.b"])
    |> staged_via_prepare("z-broken", "def M.d() : Int do\n  M.nope()\nend")
    |> staged_via_prepare("a-rm", "", remove: ["M.a"])
    |> staged_via_prepare("again", "def M.e() : Int do\n  \"s\"\nend")
    |> staged_via_prepare("later", "def M.f() : String do\n  M.g()\nend")
    |> staged_via_prepare("again", "def M.e() : Int do\n  M.c() + \"s\"\nend")
  end

  test "durable holds only ids, names and CIDs" do
    {u, _} = storied()
    durable = Lang.durable(u)
    assert %{commits: commits, staged: staged} = durable
    assert map_size(durable) == 2
    assert length(commits) == 3

    ids = Map.keys(Lang.staged(u)) ++ Enum.flat_map(commits, & &1.ids)
    names = ~w(M.a M.b M.c M.d M.e M.f)

    for b <- binaries(durable) do
      assert b in ids or b in names or b =~ @cid, "#{inspect(b)} is not an id, a name or a CID"
    end

    assert Enum.uniq(atoms(durable)) -- [:commits, :staged, :ids, :entries, :live, :gone] == []

    # Staged patches in staging order (a restaged id last), entries as staged.
    assert Enum.map(staged, &elem(&1, 0)) == ["z-broken", "a-rm", "later", "again"]
    assert {"a-rm", [{"M.a", :gone}]} in staged
    assert [{"M.d", d}] = :proplists.get_value("z-broken", staged)
    assert d =~ @cid
  end

  test "restore rebuilds committed code, history, staged patches and their reasons" do
    {u, cas} = storied()
    %{commits: commits, staged: staged} = Lang.durable(u)
    assert {:ok, r} = Lang.restore(commits, staged, decls_of(cas))

    assert Lang.committed(r) == Lang.committed(u)
    assert Lang.history(r) == Lang.history(u)
    assert Lang.signatures(r) == Lang.signatures(u)
    assert Lang.staged(r) == Lang.staged(u)
    assert Lang.durable(r) == Lang.durable(u)
    assert [%{code: "unbound"}] = Lang.reasons(r, "z-broken")

    # Only the decls restore uses need be given; extra ones are ignored.
    assert {:ok, _} = Lang.restore(commits, staged, Map.put(decls_of(cas), "junk", :junk))
    assert {:ok, empty} = Lang.restore([], [], %{})
    assert Lang.committed(empty) == %{}

    # An older history restores the code it replays to.
    assert {:ok, older} = Lang.restore(Enum.take(commits, 1), [], decls_of(cas))
    assert Enum.map(Lang.symbols(older), & &1.name) == ["M.a", "M.b"]
  end

  test "restore refuses a CID it has no declaration for, naming it" do
    {u, cas} = storied()
    %{commits: commits, staged: staged} = Lang.durable(u)
    c = Lang.committed(u)["M.c"].cid

    assert {:error, [%{name: nil, code: "restore", message: m}]} =
             Lang.restore(commits, staged, Map.delete(decls_of(cas), c))

    assert m =~ c

    [{"M.d", d}] = :proplists.get_value("z-broken", staged)

    assert {:error, [%{name: nil, code: "restore", message: m}]} =
             Lang.restore(commits, staged, Map.delete(decls_of(cas), d))

    assert m =~ d
  end

  test "restore refuses a declaration that is not the CID it is given for" do
    {u, cas} = storied()
    %{commits: commits, staged: staged} = Lang.durable(u)
    c = Lang.committed(u)["M.c"].cid
    {:ok, [other]} = Lang.parse("def M.c() : Int do\n  3\nend")

    assert {:error, [%{name: "M.c", code: "restore", message: m}]} =
             Lang.restore(commits, staged, Map.put(decls_of(cas), c, other))

    assert m =~ c

    {:ok, [renamed]} = Lang.parse("def M.x() : Int do\n  M.a()\nend")
    commits = [%{ids: ["p"], entries: [{:live, "M.c", Lang.cid(renamed)}]}]

    assert {:error, [%{name: "M.c", code: "restore"}]} =
             Lang.restore(commits, [], %{Lang.cid(renamed) => renamed})
  end

  # Committed code as stored that no longer typechecks (checker drift):
  # `M.b` calls a `M.missing` nothing defines; `M.a` is fine.
  defp drifted do
    {:ok, [a]} = Lang.parse("def M.a() : Int do\n  1\nend")
    {:ok, [b]} = Lang.parse("def M.b() : Int do\n  M.missing()\nend")

    commits = [
      %{ids: ["p"], entries: [{:live, "M.a", Lang.cid(a)}, {:live, "M.b", Lang.cid(b)}]}
    ]

    {commits, %{Lang.cid(a) => a, Lang.cid(b) => b}}
  end

  test "restore opens committed code that does not typecheck degraded, as stored" do
    {commits, decls} = drifted()

    assert {:degraded, u, [%{name: "M.b", code: "unbound"}] = reasons} =
             Lang.restore(commits, [], decls)

    assert Lang.health(u) == {:degraded, reasons}
    assert Enum.map(Lang.symbols(u), & &1.name) == ["M.a", "M.b"]
    assert {:ok, "def M.b" <> _} = Lang.read(u, "M.b")
    assert Lang.history(u) == commits
    assert Lang.durable(u) == %{commits: commits, staged: []}
  end

  test "a degraded universe promotes only a patch that makes the whole image typecheck" do
    {commits, decls} = drifted()
    {:degraded, u, _} = Lang.restore(commits, [], decls)

    # Sound on its own, but the image still fails: staged, with the image's reasons.
    assert {u, {:staged, [%{name: "M.b", code: "unbound"}]}} =
             Lang.stage(u, "other", "def M.z() : Int do\n  2\nend")

    assert {:degraded, _} = Lang.health(u)
    assert [%{name: "M.b"}] = Lang.reasons(u, "other")

    # Unstaging works while degraded.
    assert {u, true} = Lang.unstage(u, "other")
    {u, {:staged, _}} = Lang.stage(u, "other", "def M.z() : Int do\n  2\nend")

    # The fix promotes; the held-back patch promotes after it.
    assert {u, {:promoted, ["fix", "other"]}} =
             Lang.stage(u, "fix", "def M.missing() : Int do\n  3\nend")

    assert Lang.health(u) == :ok
    assert Enum.map(Lang.symbols(u), & &1.name) == ["M.a", "M.b", "M.missing", "M.z"]
    assert [_, %{ids: ["fix"]}, %{ids: ["other"]}] = Lang.history(u)
    assert {:ok, 3, _} = Kinoko.Exec.eval(Lang.snapshot(u), "M.b()")

    # Restored from what it stores now, it is sound.
    {:ok, [fix]} = Lang.parse("def M.missing() : Int do\n  3\nend")
    {:ok, [z]} = Lang.parse("def M.z() : Int do\n  2\nend")
    decls = Map.merge(decls, %{Lang.cid(fix) => fix, Lang.cid(z) => z})
    %{commits: commits} = Lang.durable(u)
    assert {:ok, _} = Lang.restore(commits, [], decls)
  end

  test "a staged patch that repairs the image promotes while restoring" do
    {commits, decls} = drifted()
    {:ok, [fix]} = Lang.parse("def M.missing() : Int do\n  3\nend")
    decls = Map.put(decls, Lang.cid(fix), fix)
    staged = [{"fix", [{"M.missing", Lang.cid(fix)}]}]

    assert {:ok, u} = Lang.restore(commits, staged, decls)
    assert Lang.health(u) == :ok
    assert [_, %{ids: ["fix"]}] = Lang.history(u)
  end

  test "prepare parses, gives each declaration's CID and canonical text, and stages nothing" do
    source = "def M.a() : Int do 1 end\ndef   M.b() : Int do\n  M.a()\nend"
    assert {:ok, entries, texts} = Lang.prepare(source, remove: ["M.z"])
    {:ok, decls} = Lang.parse(source)
    assert entries == Enum.map(decls, &{:live, &1}) ++ [{:gone, "M.z"}]
    assert texts == Enum.map(decls, &{Lang.cid(&1), Kinoko.Lang.Format.decl(&1)})
    assert {:ok, [{:gone, "M.z"}], []} = Lang.prepare("", remove: ["M.z"])

    assert {:error, [%{code: "parse", name: nil, message: m}]} = Lang.prepare("def (")
    assert m =~ ~r/\d+:\d+/
    assert {:error, [%{code: "parse"}]} = Lang.prepare(nil)
    assert {:error, [%{code: "bad-name"}]} = Lang.prepare("", remove: [:x])
    assert {:error, [%{code: "bad-name"}]} = Lang.prepare("", remove: "M.z")
  end

  test "stage_entries stages parsed entries as stage does" do
    {:ok, entries, _} = Lang.prepare(@counter)
    assert {u, {:promoted, ["counter"]}} = Lang.stage_entries(Lang.new(), "counter", entries)
    assert Lang.committed(u) == Lang.committed(promoted())

    assert {^u, {:staged, [%{code: "bad-id"}]}} = Lang.stage_entries(u, :p, entries)
    assert {^u, {:staged, [%{code: "internal"}]}} = Lang.stage_entries(u, "p", [:junk])
    bad = %{u | salsa: :not_a_database}
    assert {^bad, {:staged, [%{code: "internal"}]}} = Lang.stage_entries(bad, "p", entries)
  end

  test "snapshot holds committed code and the signatures a check sees" do
    u = promoted()
    snap = Lang.snapshot(u)
    assert %{committed: committed, signatures: sigs} = snap
    assert sigs == Lang.signatures(u)

    for {name, c} <- committed do
      assert %{cid: _, decl: _, typed: _, signature: sig} = c
      assert sig == sigs[name]
    end

    assert Lang.check_expr(snap, "Counter.init()") == Lang.check_expr(u, "Counter.init()")
    assert Lang.image(snap) == Lang.image(u)
  end

  test "Format.signature renders each kind of signature" do
    alias Kinoko.Lang.Format

    assert Format.signature("A.f", {:def, [{:named, "Int"}], {:named, "String"}}) ==
             "A.f(Int) : String"

    assert Format.signature("A.M", {:model, [{"n", {:named, "Int"}}]}) == "model {n : Int}"

    assert Format.signature("A.T", {:type, ["K"], [{"V", [{:var, "K"}]}, {"W", []}]}) ==
             "type A.T<K> = V(K) | W"

    assert Format.signature("A", :app) == "app"
    assert Format.signature("A.t", :test) == "test"
  end
end
