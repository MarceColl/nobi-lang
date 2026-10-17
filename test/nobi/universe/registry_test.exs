defmodule Nobi.Universe.RegistryTest do
  # SQLite has one writer, and each test holds its sandbox transaction open:
  # concurrent writing tests fail with "Database busy", so this one is sync.
  use Nobi.DataCase, async: false

  alias Nobi.Universe.Registry

  test "create then exists? and list" do
    refute Registry.exists?("alpha")
    assert :ok = Registry.create("alpha")
    assert :ok = Registry.create("beta", parent: "alpha", forked_at_commit: 3)
    assert Registry.exists?("alpha")

    assert [
             %{name: "alpha", parent: nil, forked_at_commit: nil, created_at: %DateTime{}},
             %{name: "beta", parent: "alpha", forked_at_commit: 3}
           ] = Registry.list() |> Enum.filter(&(&1.name in ["alpha", "beta"]))
  end

  test "duplicate create is :exists" do
    assert :ok = Registry.create("dup")
    assert {:error, :exists} = Registry.create("dup")
  end

  test "bad names" do
    for n <- ["", "Upper", "-x", "a b", String.duplicate("a", 64), "a/b"] do
      assert {:error, :bad_name} = Registry.create(n)
    end

    assert {:error, :bad_name} = Registry.create(nil)
  end

  test "concurrent creates give exactly one :ok" do
    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Registry.create("race") end) end)
      |> Task.await_many()

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :exists})) == 9
  end

  test "ensure_main is idempotent" do
    assert :ok = Registry.ensure_main()
    assert :ok = Registry.ensure_main()
    assert Registry.exists?("main")
  end
end
