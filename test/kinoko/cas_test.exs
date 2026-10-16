defmodule Kinoko.CasTest do
  # SQLite has one writer, and each test holds its sandbox transaction open:
  # concurrent writing tests fail with "Database busy", so this one is sync.
  use Kinoko.DataCase, async: false

  alias Kinoko.Cas

  test "put is idempotent" do
    assert :ok = Cas.put([{"c1", "text"}])
    assert :ok = Cas.put([{"c1", "text"}])
    assert Repo.aggregate(from(d in "declarations", where: d.cid == "c1"), :count) == 1
  end

  test "put of an empty list is a no-op" do
    assert :ok = Cas.put([])
  end

  test "get returns only existing cids" do
    :ok = Cas.put([{"a", "A"}, {"b", "B"}])
    assert Cas.get(["a", "b", "zzz"]) == %{"a" => "A", "b" => "B"}
    assert Cas.get([]) == %{}
  end

  test "concurrent puts of the same cid all succeed" do
    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Cas.put([{"same", "T"}]) end) end)
      |> Task.await_many()

    assert Enum.all?(results, &(&1 == :ok))
    assert Cas.get(["same"]) == %{"same" => "T"}
  end

  test "very large batches are chunked" do
    pairs = for i <- 1..40_000, do: {"big-#{i}", "t"}
    assert :ok = Cas.put(pairs)
    assert map_size(Cas.get(Enum.map(pairs, &elem(&1, 0)))) == 40_000
  end
end
