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

  test "pin and follow broadcast deployment_changed on the deployment's topic" do
    u = fresh_universe()
    n = dname()
    assert {:promoted, _} = Universe.stage(u, "one", @v1)
    :ok = Deployment.create(n, u, "Main")
    :ok = Phoenix.PubSub.subscribe(Kinoko.PubSub, Deployment.topic(n))

    :ok = Deployment.pin(n, 1)
    assert_receive {:deployment_changed, ^n}
    :ok = Deployment.follow(n)
    assert_receive {:deployment_changed, ^n}

    {:error, :no_such_commit} = Deployment.pin(n, 9)
    refute_receive {:deployment_changed, _}, 50
  end

  test "<name>.localhost resolves only where :localhost_deployments is on" do
    u = fresh_universe()
    n = dname()
    :ok = Deployment.create(n, u, "Main", hosts: ["app.example.com"])
    previous = Application.fetch_env(:kinoko, :localhost_deployments)
    Application.put_env(:kinoko, :localhost_deployments, false)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:kinoko, :localhost_deployments, v)
        :error -> Application.delete_env(:kinoko, :localhost_deployments)
      end
    end)

    assert :error = Deployment.resolve("#{n}.localhost")
    assert {:ok, %{name: ^n}} = Deployment.resolve("app.example.com")
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

  describe "a deployment never takes another's host" do
    test "loopback names are local's: reserved" do
      u = fresh_universe()

      for host <-
            ~w(::1 [::1] [::1]:4000 127.1.2.3 127.255.255.255 127.0.0.1:80 0.0.0.0 0.0.0.0:4000),
          do:
            assert(
              {:error, :reserved_host} = Deployment.create(dname(), u, "Main", hosts: [host])
            )

      assert :ok = Deployment.create(dname(), u, "Main", hosts: ["127.example.com"])

      for host <- [
            "localhost",
            "LOCALHOST:4000",
            "127.0.0.1",
            "[::1]",
            "[::1]:4000",
            "localhost."
          ],
          do:
            assert(
              {:error, :reserved_host} = Deployment.create(dname(), u, "Main", hosts: [host])
            )
    end

    test "another deployment's <name>.localhost is foreign; its own is fine" do
      u = fresh_universe()
      a = dname()
      b = dname()
      :ok = Deployment.create(a, u, "Main")

      assert {:error, :foreign_localhost} =
               Deployment.create(b, u, "Main", hosts: ["#{a}.localhost"])

      assert {:error, :foreign_localhost} =
               Deployment.create(b, u, "Main", hosts: ["x.#{b}.localhost"])

      assert {:ok, %{name: ^a}} = Deployment.resolve("#{a}.localhost")
      assert :ok = Deployment.create(b, u, "Main", hosts: ["#{b}.localhost"])
    end

    test "a host another deployment lists is taken, and nothing is written" do
      u = fresh_universe()
      a = dname()
      b = dname()
      :ok = Deployment.create(a, u, "Main", hosts: ["shop.example.com"])

      assert {:error, :host_taken} =
               Deployment.create(b, u, "Main", hosts: ["new.example.com", "Shop.Example.com:80"])

      assert :error = Deployment.get(b)
      assert :error = Deployment.resolve("new.example.com")
      assert {:ok, %{name: ^a}} = Deployment.resolve("shop.example.com")
    end

    test "a host that is not a DNS name is bad_host" do
      u = fresh_universe()

      for host <- [
            "",
            "a b.com",
            "-a.com",
            "a-.com",
            "a..com",
            "a_b.com",
            "a/b",
            String.duplicate("a", 64) <> ".com"
          ],
          do: assert({:error, :bad_host} = Deployment.create(dname(), u, "Main", hosts: [host]))

      assert :ok = Deployment.create(dname(), u, "Main", hosts: ["a-1.b2.example.com"])
    end

    test "local keeps localhost after an attempted hijack" do
      :ok = Deployment.ensure_local()
      u = fresh_universe()

      assert {:error, :reserved_host} =
               Deployment.create("a", u, "Main", hosts: ["localhost", "127.0.0.1"])

      assert {:error, :foreign_localhost} =
               Deployment.create(dname(), u, "Main", hosts: ["local.localhost"])

      assert {:ok, %{name: "local"}} = Deployment.resolve("localhost")
      assert {:ok, %{name: "local"}} = Deployment.resolve("127.0.0.1")
      assert {:ok, %{name: "local"}} = Deployment.resolve("local.localhost")
    end
  end

  test "strip_port: after ] or as the only colon; ::1 keeps its colons" do
    assert Deployment.strip_port("a.com:80") == "a.com"
    assert Deployment.strip_port("a.com") == "a.com"
    assert Deployment.strip_port("[::1]:4000") == "[::1]"
    assert Deployment.strip_port("[::1]") == "[::1]"
    assert Deployment.strip_port("::1") == "::1"
    assert Deployment.strip_port("a.com:x") == "a.com:x"
  end

  describe "repair_hosts (rows from before hosts were checked)" do
    # Writes host rows past create/4's checks, as older code could.
    defp seed_hosts(rows) do
      Kinoko.Repo.insert_all(
        "deployment_hosts",
        for({d, host, pos} <- rows, do: %{deployment: d, host: host, position: pos})
      )
    end

    test "drops loopback and foreign *.localhost hosts, keeps the rest" do
      u = fresh_universe()
      a = dname()
      b = dname()
      :ok = Deployment.create(a, u, "Main")
      :ok = Deployment.create(b, u, "Main")

      seed_hosts([
        {a, "localhost", 0},
        {b, "127.0.0.9", 0},
        {a, "#{b}.localhost", 1},
        {a, "#{a}.localhost", 2},
        {b, "ok.example.com", 1}
      ])

      assert Deployment.repair_hosts() == 3
      own = "#{a}.localhost"
      assert {:ok, %{hosts: [^own]}} = Deployment.get(a)
      assert {:ok, %{hosts: ["ok.example.com"]}} = Deployment.get(b)
    end

    test "a host claimed twice stays with the deployment resolve served" do
      u = fresh_universe()
      a = "a-#{System.unique_integer([:positive])}"
      b = "b-#{System.unique_integer([:positive])}"
      :ok = Deployment.create(a, u, "Main")
      :ok = Deployment.create(b, u, "Main")
      # The unique index is what forbids this now; the sandbox rolls the drop back.
      Kinoko.Repo.query!("DROP INDEX deployment_hosts_host_index")
      seed_hosts([{b, "dup.example.com", 0}, {a, "dup.example.com", 0}])

      assert Deployment.repair_hosts() == 1
      assert {:ok, %{name: ^a}} = Deployment.resolve("dup.example.com")
      assert {:ok, %{hosts: []}} = Deployment.get(b)
    end

    test "the migration's own repair drops the same bad rows" do
      [{mod, _}] =
        Code.require_file("priv/repo/migrations/20261017160000_unique_deployment_hosts.exs")
        |> Enum.filter(fn {m, _} -> m == Kinoko.Repo.Migrations.UniqueDeploymentHosts end)

      u = fresh_universe()
      a = "a-#{System.unique_integer([:positive])}"
      b = "b-#{System.unique_integer([:positive])}"
      :ok = Deployment.create(a, u, "Main")
      :ok = Deployment.create(b, u, "Main")
      Kinoko.Repo.query!("DROP INDEX deployment_hosts_host_index")

      seed_hosts([
        {a, "localhost", 0},
        {b, "127.0.0.9", 0},
        {a, "#{b}.localhost", 1},
        {b, "dup.example.com", 1},
        {a, "dup.example.com", 2},
        {b, "ok.example.com", 2}
      ])

      assert mod.repair(Kinoko.Repo) == 4
      assert {:ok, %{hosts: ["dup.example.com"]}} = Deployment.get(a)
      assert {:ok, %{hosts: ["ok.example.com"]}} = Deployment.get(b)
    end

    test "ensure_local takes localhost back from a deployment that held it" do
      u = fresh_universe()
      x = dname()
      :ok = Deployment.create(x, u, "Main")
      seed_hosts([{x, "localhost", 0}])

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Deployment.ensure_local() end)
      assert log =~ "removed 1 host"
      assert {:ok, %{name: "local"}} = Deployment.resolve("localhost")
      assert {:ok, %{hosts: []}} = Deployment.get(x)
    end
  end

  test "localhost_deployments?/0 follows :localhost_deployments" do
    previous = Application.fetch_env(:kinoko, :localhost_deployments)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:kinoko, :localhost_deployments, v)
        :error -> Application.delete_env(:kinoko, :localhost_deployments)
      end
    end)

    Application.put_env(:kinoko, :localhost_deployments, false)
    refute Deployment.localhost_deployments?()
    Application.put_env(:kinoko, :localhost_deployments, true)
    assert Deployment.localhost_deployments?()
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

  test "create validates commit like pin" do
    u = fresh_universe()
    assert {:promoted, _} = Universe.stage(u, "one", @v1)
    assert :ok = Deployment.create(dname(), u, "Main", commit: 1)
    assert {:error, :no_such_commit} = Deployment.create(dname(), u, "Main", commit: 2)
    assert {:error, :no_such_commit} = Deployment.create(dname(), u, "Main", commit: 0)
    assert {:error, :no_such_commit} = Deployment.create(dname(), u, "Main", commit: "1")
    assert {:error, :no_such_commit} = Deployment.create(dname(), u, "Main", commit: :x)
  end

  test "host normalization: trailing dot, port" do
    u = fresh_universe()
    n = dname()
    :ok = Deployment.create(n, u, "Main", hosts: ["App.Example.com.:4000"])
    assert {:ok, %{hosts: ["app.example.com"]}} = Deployment.get(n)
    assert {:ok, %{name: ^n}} = Deployment.resolve("app.example.com.")
    assert {:ok, %{name: ^n}} = Deployment.resolve("app.example.com.:4000")
    assert {:ok, %{name: ^n}} = Deployment.resolve("#{n}.localhost.")
    assert {:ok, %{name: ^n}} = Deployment.resolve("#{n}.localhost.:4000")
    :ok = Deployment.ensure_local()
    assert {:ok, %{name: "local"}} = Deployment.resolve("localhost.")
    assert :error = Deployment.resolve("")
  end

  test "duplicate hosts collapse to one" do
    u = fresh_universe()
    n = dname()

    :ok =
      Deployment.create(n, u, "Main",
        hosts: ["A.example.com", "a.example.com:80", "b.example.com"]
      )

    assert {:ok, %{hosts: ["a.example.com", "b.example.com"]}} = Deployment.get(n)
  end

  test "non-string arguments are bad_name, never a raise" do
    u = fresh_universe()
    assert {:error, :bad_name} = Deployment.create(dname(), nil, "Main")
    assert {:error, :bad_name} = Deployment.create(dname(), u, nil)
    assert {:error, :bad_name} = Deployment.create(dname(), u, "Main", hosts: [1])
    assert {:error, :bad_name} = Deployment.create(dname(), u, "Main", hosts: "x")
    assert :error = Deployment.resolve(nil)
    assert :error = Deployment.get(nil)
  end

  test "concurrent creates give exactly one :ok" do
    u = fresh_universe()
    n = dname()

    results =
      1..10
      |> Task.async_stream(fn _ -> Deployment.create(n, u, "Main") end, timeout: :infinity)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :exists})) == 9
  end
end
