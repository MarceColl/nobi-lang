defmodule Kinoko.Elm.StoreTest do
  # SQLite has one writer, and each test holds its sandbox transaction open:
  # concurrent writing tests fail with "Database busy", so this one is sync.
  use Kinoko.DataCase, async: false

  alias Kinoko.Elm.Store

  test "append then latest" do
    assert Store.latest("a") == :none
    assert :ok = Store.append("a", 0, "M", 1, <<1>>)
    assert :ok = Store.append("a", 1, "M", 2, <<2>>)
    assert {:ok, %{seq: 1, module: "M", version: 2, state: <<2>>}} = Store.latest("a")
  end

  test "history is newest first and limited" do
    for i <- 0..4, do: Store.append("a", i, "M", 1, <<i>>)
    assert [%{seq: 4}, %{seq: 3}] = Store.history("a", 2)
    assert [%{seq: 4, inserted_at: %DateTime{}} | _] = Store.history("a")
    assert length(Store.history("a")) == 5
  end

  test "prune keeps the newest N" do
    for i <- 0..4, do: Store.append("a", i, "M", 1, <<i>>)
    assert Store.prune("a", 2) == 3
    assert [4, 3] == Enum.map(Store.history("a"), & &1.seq)
  end

  test "duplicate (key, seq) raises" do
    Store.append("a", 0, "M", 1, <<1>>)
    assert_raise Exqlite.Error, fn -> Store.append("a", 0, "M", 1, <<2>>) end
  end

  test "keys are independent" do
    Store.append("a", 0, "M", 1, <<1>>)
    Store.append("b", 0, "M", 1, <<2>>)
    Store.append("b", 1, "M", 1, <<3>>)
    assert {:ok, %{seq: 0, state: <<1>>}} = Store.latest("a")
    assert {:ok, %{seq: 1}} = Store.latest("b")
    assert Store.prune("b", 1) == 1
    assert [%{seq: 0}] = Store.history("a")
  end

  test "prune edge cases: unknown key, keep >= rows" do
    assert Store.prune("none", 3) == 0
    for i <- 0..2, do: Store.append("a", i, "M", 1, <<i>>)
    assert Store.prune("a", 3) == 0
    assert Store.prune("a", 10) == 0
    assert length(Store.history("a")) == 3
    assert Store.prune("a", 1) == 2
    assert [%{seq: 2}] = Store.history("a")
  end

  test "state binaries round-trip byte for byte" do
    bin = :erlang.term_to_binary(%{bytes: <<0, 255, 0, 1>>, text: "ñ\0x", n: 1.5})
    big = :crypto.strong_rand_bytes(2_000_000)
    Store.append("a", 0, "M", 1, bin)
    Store.append("b", 0, "M", 1, big)
    assert {:ok, %{state: ^bin}} = Store.latest("a")
    assert {:ok, %{state: ^big}} = Store.latest("b")
  end
end
