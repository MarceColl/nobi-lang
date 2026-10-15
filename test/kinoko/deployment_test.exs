defmodule Kinoko.DeploymentTest do
  use Kinoko.DataCase, async: false

  import Kinoko.UniverseHelpers

  alias Kinoko.{Deployment, Universe}

  @v1 "def A.one() : Int do 1 end"
  @v2 "def A.two() : Int do 2 end"

  defp dname, do: "d-#{System.unique_integer([:positive])}"

  test "create, get, list" do
    u = fresh_universe()
    n = dname()
    assert :ok = Deployment.create(n, u, "Main", hosts: ["Shop.Example.com"])

    assert {:ok,
            %{name: ^n, universe: ^u, routes: "Main", commit: nil, hosts: ["shop.example.com"]}} =
             Deployment.get(n)

    assert :error = Deployment.get("nope")
    assert n in Enum.map(Deployment.list(), & &1.name)
  end

  test "duplicate, bad name, unknown universe" do
    u = fresh_universe()
    n = dname()
    assert :ok = Deployment.create(n, u, "Main")
    assert {:error, :exists} = Deployment.create(n, u, "Main")
    assert {:error, :bad_name} = Deployment.create("Bad Name", u, "Main")
    assert {:error, :bad_name} = Deployment.create(nil, u, "Main")
    assert {:error, :no_such_universe} = Deployment.create(dname(), "ghost", "Main")
  end

  test "pin and follow round trip" do
    u = fresh_universe()
    n = dname()
    assert {:promoted, _} = Universe.stage(u, "one", @v1)
    :ok = Deployment.create(n, u, "Main")

    assert :ok = Deployment.pin(n, 1)
    assert {:ok, %{commit: 1}} = Deployment.get(n)
    assert :ok = Deployment.follow(n)
    assert {:ok, %{commit: nil}} = Deployment.get(n)

    assert {:error, :no_such_commit} = Deployment.pin(n, 2)
    assert {:error, :no_such_commit} = Deployment.pin(n, 0)
    assert {:error, :no_such_commit} = Deployment.pin(n, "1")
    assert {:error, :not_found} = Deployment.pin("nope", 1)
    assert {:error, :not_found} = Deployment.follow("nope")
  end

  test "resolve: exact host, <name>.localhost, unknown" do
    u = fresh_universe()
    n = dname()
    other = dname()
    :ok = Deployment.create(n, u, "Main", hosts: ["app.example.com"])
    :ok = Deployment.create(other, u, "Main")

    assert {:ok, %{name: ^n}} = Deployment.resolve("app.example.com")
    assert {:ok, %{name: ^n}} = Deployment.resolve("APP.example.com:4000")
    assert {:ok, %{name: ^other}} = Deployment.resolve("#{other}.localhost")
    assert {:ok, %{name: ^other}} = Deployment.resolve("#{String.upcase(other)}.localhost:4000")
    assert :error = Deployment.resolve("unknown.example.com")
    assert :error = Deployment.resolve("nope.localhost")
    assert :error = Deployment.resolve("a.b.localhost")
  end

  test "exact host wins over <name>.localhost" do
    u = fresh_universe()
    a = dname()
    b = dname()
    :ok = Deployment.create(a, u, "Main")
    :ok = Deployment.create(b, u, "Main", hosts: ["#{a}.localhost"])
    assert {:ok, %{name: ^b}} = Deployment.resolve("#{a}.localhost")
  end

  test "ensure_local is idempotent and serves localhost" do
    assert :ok = Deployment.ensure_local()
    assert :ok = Deployment.ensure_local()

    assert {:ok,
            %{universe: "main", routes: "Main", commit: nil, hosts: ["localhost", "127.0.0.1"]}} =
             Deployment.get("local")

    assert {:ok, %{name: "local"}} = Deployment.resolve("localhost:4000")
    assert {:ok, %{name: "local"}} = Deployment.resolve("127.0.0.1")
    assert {:ok, %{name: "local"}} = Deployment.resolve("local.localhost")
  end

  test "a pinned deployment serves the old commit after a promotion; re-pin changes it" do
    u = fresh_universe()
    n = dname()
    assert {:promoted, _} = Universe.stage(u, "one", @v1)
    :ok = Deployment.create(n, u, "Main")
    :ok = Deployment.pin(n, 1)

    {:ok, d} = Deployment.get(n)
    assert {:ok, %Universe.At{commit: 1} = at1} = Deployment.target(d)

    assert {:promoted, _} = Universe.stage(u, "two", @v2)
    assert {:ok, %Universe.At{commit: 1}} = Deployment.target(d)
    assert {:ok, 1, _} = Universe.call(at1, "A.one", [], [])
    assert {:error, _} = Universe.call(at1, "A.two", [], [])

    :ok = Deployment.pin(n, 2)
    {:ok, d2} = Deployment.get(n)
    assert {:ok, %Universe.At{commit: 2} = at2} = Deployment.target(d2)
    assert {:ok, 2, _} = Universe.call(at2, "A.two", [], [])

    :ok = Deployment.follow(n)
    {:ok, d3} = Deployment.get(n)
    assert {:ok, ^u} = Deployment.target(d3)
  end
end
