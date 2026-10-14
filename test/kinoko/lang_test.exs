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
      assert %{cid: cid, decl: _, typed: typed, deps: %MapSet{}, signature: sig} = c
      assert Lang.text(u, cid) == Kinoko.Lang.Format.decl(c.decl)
      assert sig == Lang.signatures(u)[name]
      assert typed != nil
    end

    assert {:def, [{:named, _} | _], _} = committed["Counter.update"].signature
    assert Lang.text(u, "nope") == nil
  end

  test "restore rebuilds a universe from its history and texts" do
    u = promoted()
    texts = for {_, %{cid: cid}} <- Lang.committed(u), into: %{}, do: {cid, Lang.text(u, cid)}
    assert {:ok, r} = Lang.restore(Lang.history(u), texts)
    assert Lang.symbols(r) == Lang.symbols(u)
    assert {:error, [%{code: "restore"} | _]} = Lang.restore(Lang.history(u), %{})
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
