defmodule Kinoko.LangTest do
  use ExUnit.Case, async: true

  doctest Kinoko.Lang

  alias Kinoko.Lang

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
end
