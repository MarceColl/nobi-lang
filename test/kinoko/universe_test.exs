defmodule Kinoko.UniverseTest do
  use Kinoko.DataCase, async: false

  import ExUnit.CaptureLog
  import Kinoko.UniverseHelpers

  alias Kinoko.{Exec, Universe}
  alias Kinoko.Universe.Registry

  @g "def A.g() : Int do\n  1\nend"
  @f "def A.f() : Int do\n  A.g()\nend"
  @counter File.read!("test/fixtures/yabu/counter.yabu")

  setup do
    %{u: fresh_universe()}
  end

  describe "list and create" do
    test "create, then list it; duplicates and bad names are refused", %{u: u} do
      assert %{name: ^u, parent: nil, created_at: %DateTime{}} =
               Enum.find(Universe.list(), &(&1.name == u))

      assert {:error, :exists} = Universe.create(u)
      assert {:error, :bad_name} = Universe.create("Bad Name")
    end

    test "an unknown universe is :no_such_universe, a bad name :bad_name" do
      for f <- [
            &Universe.symbols/1,
            &Universe.staged/1,
            &Universe.history/1,
            &Universe.read(&1, "A.f"),
            &Universe.stage(&1, "p1", @g),
            &Universe.unstage(&1, "p1"),
            &Universe.eval(&1, "1", []),
            &Universe.call(&1, "A.g", [], []),
            &Universe.test(&1, "A.t", [])
          ] do
        assert {:error, :no_such_universe} = f.("nope-#{System.unique_integer([:positive])}")
        assert {:error, :bad_name} = f.("Not A Name")
      end

      assert Kinoko.PersistentElmGenServer.whereis("universe:nope") == nil
    end

    test "main is created on first use when the boot task did not create it" do
      stop_on_exit("main")
      refute Registry.exists?("main")
      assert [] = Universe.symbols("main")
      assert Registry.exists?("main")
    end

    test "a stopped universe is started on demand", %{u: u} do
      assert pid(u) == nil
      assert [] = Universe.symbols(u)
      assert is_pid(pid(u))
    end
  end

  describe "stage, promote and read" do
    test "a promoted patch is readable and listed", %{u: u} do
      assert {:promoted, ["p1"]} = Universe.stage(u, "p1", @g)
      assert {:ok, "def A.g" <> _} = Universe.read(u, "A.g")
      assert :error = Universe.read(u, "A.nope")
      assert [%{symbol: "A.g", cid: cid, signature: sig}] = Universe.symbols(u)
      assert cid =~ ~r/^[0-9a-f]{64}$/
      assert is_binary(sig)
      assert [%{ids: ["p1"], entries: [{:live, "A.g", ^cid}]}] = Universe.history(u)
      assert [] = Universe.staged(u)
    end

    test "a broken patch is staged with reasons, fixed, then promoted", %{u: u} do
      assert {:staged, [%{code: "unbound"}]} = Universe.stage(u, "p1", @f)

      assert [%{id: "p1", source: "def A.f" <> _, removes: [], reasons: [%{code: "unbound"}]}] =
               Universe.staged(u)

      assert {:ok, "def A.f" <> _} = Universe.read(u, "A.f")
      assert [] = Universe.symbols(u)

      assert {:promoted, ["p1"]} = Universe.stage(u, "p1", @g <> "\n\n" <> @f)
      assert ["A.f", "A.g"] = Enum.map(Universe.symbols(u), & &1.symbol)
      assert [] = Universe.staged(u)
    end

    test "remove: stages a removal", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      assert {:promoted, ["p2"]} = Universe.stage(u, "p2", "", remove: ["A.g"])
      assert [] = Universe.symbols(u)
    end

    test "unstage", %{u: u} do
      {:staged, _} = Universe.stage(u, "p1", @f)
      assert :ok = Universe.unstage(u, "p1")
      assert :not_found = Universe.unstage(u, "p1")
      assert [] = Universe.staged(u)
    end

    test "a non-string id is refused in the caller", %{u: u} do
      assert {:staged, [%{code: "bad-id"}]} = Universe.stage(u, :p1, @g)
      assert {:staged, [%{code: "bad-name"}]} = Universe.stage(u, "p1", @g, remove: [:x])
      assert [] = Universe.history(u)
    end

    test "two universes are independent", %{u: u} do
      v = fresh_universe()
      {:promoted, _} = Universe.stage(u, "p1", @g)
      {:staged, _} = Universe.stage(v, "p1", @f)

      assert ["A.g"] = Enum.map(Universe.symbols(u), & &1.symbol)
      assert [] = Universe.symbols(v)
      assert [] = Universe.staged(u)
      assert [%{id: "p1"}] = Universe.staged(v)
      assert pid(u) != pid(v)
    end
  end

  describe "a parse error" do
    test "never stages anything: no row is written and seq is unchanged", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      before = rows(u)

      assert {:staged, [%{code: "parse", message: msg}]} = Universe.stage(u, "p2", "def (((")
      assert msg =~ ~r/^\d+:\d+: /
      assert rows(u) == before
      assert [] = Universe.staged(u)
    end

    test "unstages what the id staged before, so it never promotes later", %{u: u} do
      assert {:staged, _} = Universe.stage(u, "p1", @f)
      assert {:staged, [%{code: "parse"}]} = Universe.stage(u, "p1", "def (((")
      assert [] = Universe.staged(u)

      # Were the stale p1 still staged, it would promote alongside A.g.
      assert {:promoted, ["p2"]} = Universe.stage(u, "p2", @g)
      assert ["A.g"] = Enum.map(Universe.symbols(u), & &1.symbol)
      assert [%{ids: ["p2"]}] = Universe.history(u)
    end
  end

  describe "restart" do
    test "a stopped CodeDb restarts with commits and staged patches intact", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      {:staged, _} = Universe.stage(u, "p2", "def A.h() : Int do\n  A.nope()\nend")
      symbols = Universe.symbols(u)
      history = Universe.history(u)
      staged = Universe.staged(u)

      stop(u)
      assert pid(u) == nil

      assert Universe.symbols(u) == symbols
      assert Universe.history(u) == history
      assert Universe.staged(u) == staged
    end

    # Review Focus 2.
    test "a killed CodeDb is transparently restarted from the DB, reasons recomputed", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)

      {:staged, [%{code: "unbound"}]} =
        Universe.stage(u, "p2", "def A.h() : Int do\n  A.k()\nend")

      old = pid(u)
      ref = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old, :killed}

      # Straight after the kill: whether the supervisor or Universe starts it.
      assert [%{id: "p2", reasons: [%{code: "unbound", message: m}]}] = Universe.staged(u)
      assert m =~ "A.k"
      assert ["A.g"] = Enum.map(Universe.symbols(u), & &1.symbol)
      assert pid(u) != old

      # The restored universe works: the fix promotes the staged patch.
      assert {:promoted, ["p2"]} =
               Universe.stage(
                 u,
                 "p2",
                 "def A.k() : Int do\n  2\nend\n\ndef A.h() : Int do\n  A.k()\nend"
               )
    end
  end

  describe "eval, call and test" do
    test "run against the current commit", %{u: u} do
      {:promoted, _} = Universe.stage(u, "c", @counter)

      assert {:ok, {model, _cmd}, _type} =
               Universe.eval(
                 u,
                 "Counter.update(Counter.Msg.Add(2), %Counter.Model{count: 1})",
                 []
               )

      assert Exec.show(model, {:named, "Counter.Model"}) == "%Counter.Model{count: 3}"

      {:promoted, _} =
        Universe.stage(u, "m", """
        def M.double(n : Int) : Int do
          n * 2
        end

        deftest M.doubles do
          always(M.double(2) == 4)
        end

        deftest M.wrong do
          always(M.double(3) == 7)
        end
        """)

      assert {:ok, 8, {:named, "Int"}} = Universe.call(u, "M.double", [4], [])
      assert :ok = Universe.test(u, "M.doubles", [])
      assert {:error, %{code: "test"}} = Universe.test(u, "M.wrong", [])
      assert {:error, %{code: "unbound"}} = Universe.eval(u, "M.nope(1)", [])

      # A staged change is not the current commit.
      {:staged, _} =
        Universe.stage(u, "m2", "def M.double(n : Int) : Int do\n  M.nope(n)\nend")

      assert {:ok, 8, {:named, "Int"}} = Universe.call(u, "M.double", [4], [])
    end

    test "see a newly promoted commit", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      assert {:ok, 1, _} = Universe.eval(u, "A.g()", [])
      {:promoted, _} = Universe.stage(u, "p1b", "def A.g() : Int do\n  5\nend")
      assert {:ok, 5, _} = Universe.eval(u, "A.g()", [])
    end

    test "a program built on the Map stdlib promotes and evaluates", %{u: u} do
      src = """
      def M.build() : Map<String, Int> do
        m = Map.from_list([("b", 2), ("a", 1)])
        Map.put(m, "c", 3)
      end

      def M.lookup(m : Map<String, Int>, k : String) : Int do
        case Map.get(m, k) do
          Option.Some(n) -> n
          Option.None -> 0
        end
      end
      """

      assert {:promoted, ["maps"]} = Universe.stage(u, "maps", src)

      assert {:ok, {3, 0, [{"a", 1}, {"b", 2}, {"c", 3}]}, _} =
               Universe.eval(
                 u,
                 ~s|(M.lookup(M.build(), "c"), M.lookup(M.build(), "z"), Map.to_list(M.build()))|,
                 []
               )
    end
  end

  # The process running `module`'s code (the eval's worker), once there is one.
  defp await_running(module) do
    Enum.find_value(1..500, fn _ ->
      Enum.find(Process.list(), &running?(&1, module)) || (Process.sleep(2) && nil)
    end) || flunk("no process ever ran #{module}")
  end

  defp running?(pid, module) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, frames} -> Enum.any?(frames, &match?({^module, _, _, _}, &1))
      nil -> false
    end
  end

  describe "degraded" do
    test "committed code that no longer typechecks boots degraded, and a fix heals it", %{u: u} do
      store_commit(u, @f)

      log =
        capture_log(fn ->
          assert {:degraded, [%{name: "A.f", code: "unbound"}]} = Universe.health(u)
        end)

      assert log =~ "degraded"

      # Reading works, as stored.
      assert [%{symbol: "A.f"}] = Universe.symbols(u)
      assert {:ok, "def A.f" <> _} = Universe.read(u, "A.f")
      assert [%{ids: ["old"]}] = Universe.history(u)

      # Nothing runs.
      assert {:error, %{code: "degraded", message: m}} = Universe.eval(u, "1", [])
      assert m =~ "`A.f`"
      assert {:error, %{code: "degraded"}} = Universe.call(u, "A.f", [], [])
      assert {:error, %{code: "degraded"}} = Universe.test(u, "A.t", [])

      # A sound patch that leaves the image broken stays staged with the
      # image's reasons; unstaging works.
      assert {:staged, [%{name: "A.f", code: "unbound"}]} =
               Universe.stage(u, "other", "def B.x() : Int do\n  2\nend")

      assert [%{id: "other", reasons: [%{name: "A.f"}]}] = Universe.staged(u)
      assert :ok = Universe.unstage(u, "other")

      # The fix promotes; the universe is healthy and runs.
      assert {:promoted, ["fix"]} = Universe.stage(u, "fix", @g)
      assert :ok = Universe.health(u)
      assert {:ok, 1, _} = Universe.eval(u, "A.f()", [])
      assert [%{ids: ["old"]}, %{ids: ["fix"]}] = Universe.history(u)

      # And it boots healthy from what it stored.
      stop(u)
      assert :ok = Universe.health(u)
      assert {:ok, 1, _} = Universe.eval(u, "A.f()", [])
    end

    test "health is :ok for a sound universe", %{u: u} do
      assert :ok = Universe.health(u)
      {:promoted, _} = Universe.stage(u, "p1", @g)
      assert :ok = Universe.health(u)
      assert {:error, :no_such_universe} = Universe.health("nope-health")
    end
  end

  describe "errors" do
    test "list and create answer unavailable when the database fails" do
      Repo.query!("ALTER TABLE universes RENAME TO universes_away")

      assert {:error, %{code: "unavailable"}} = Universe.list()
      assert {:error, %{code: "unavailable"}} = Universe.create("any")

      Repo.query!("ALTER TABLE universes_away RENAME TO universes")
      assert is_list(Universe.list())
    end

    test "an eval naming a symbol only a staged patch defines says so", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      {:staged, _} = Universe.stage(u, "wip", "def A.h() : Int do\n  A.nope()\nend")

      assert {:error, %{code: "unbound", message: m}} = Universe.eval(u, "A.h()", [])
      assert m =~ "(staged under `wip`, not promoted)"

      assert {:error, %{code: "runtime", message: m}} = Universe.call(u, "A.h", [], [])
      assert m =~ "(staged under `wip`, not promoted)"

      # Nothing staged defines it: the message is as it was.
      assert {:error, %{code: "unbound", message: m}} = Universe.eval(u, "A.zz()", [])
      refute m =~ "staged under"
    end

    test "a CodeDb answers a request it does not know with an error", %{u: u} do
      [] = Universe.symbols(u)
      assert {:error, :unknown_request} = Kinoko.PersistentElmGenServer.call(key(u), :bogus)
      assert [] = Universe.symbols(u)
    end
  end

  describe "review focus" do
    # 1. Two concurrent stages to the same universe from different processes.
    test "concurrent stages are serialized, each verdict correct, history consistent", %{u: u} do
      [a, b] =
        Task.await_many([
          Task.async(fn -> Universe.stage(u, "pf", @f) end),
          Task.async(fn -> Universe.stage(u, "pg", @g) end)
        ])

      # Either order is fine: g first, then f promotes on its own; f first
      # stays staged (unbound) until g's round promotes it too.
      case a do
        {:promoted, ["pf"]} ->
          assert b == {:promoted, ["pg"]}

        {:staged, [%{code: "unbound"}]} ->
          assert {:promoted, ids} = b
          assert Enum.sort(ids) == ["pf", "pg"]
      end

      assert ["A.f", "A.g"] = Enum.map(Universe.symbols(u), & &1.symbol)
      assert [] = Universe.staged(u)

      ids = Universe.history(u) |> Enum.flat_map(& &1.ids)
      assert Enum.sort(ids) == ["pf", "pg"]

      results =
        1..20
        |> Enum.map(fn i ->
          Task.async(fn -> Universe.stage(u, "c#{i}", "def C.f#{i}() : Int do\n  #{i}\nend") end)
        end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:promoted, [_]}, &1))
      ids = Universe.history(u) |> Enum.flat_map(& &1.ids)
      assert length(ids) == 22 and length(Enum.uniq(ids)) == 22
      assert length(Universe.symbols(u)) == 22
    end

    # 3. A CAS row missing for a referenced CID.
    test "a missing CAS row refuses boot naming the CID; the caller survives", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      [%{cid: cid}] = Universe.symbols(u)
      stop(u)
      Repo.delete_all(from d in "declarations", where: d.cid == ^cid)

      capture_log(fn ->
        assert {:error, %{code: "internal", message: message}} = Universe.symbols(u)
        assert message =~ cid
        assert {:error, %{code: "internal"}} = Universe.stage(u, "p2", @f)
        assert {:error, %{code: "internal"}} = Universe.eval(u, "1", [])
      end)

      assert pid(u) == nil
    end

    test "a crashed universe that cannot boot again is dropped, not restarted in a loop", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      [%{cid: cid}] = Universe.symbols(u)
      Repo.delete_all(from d in "declarations", where: d.cid == ^cid)
      sup = Process.whereis(Kinoko.Elm.Supervisor)
      old = pid(u)

      capture_log(fn ->
        ref = Process.monitor(old)
        Process.exit(old, :kill)
        assert_receive {:DOWN, ^ref, :process, ^old, :killed}
        Process.sleep(100)

        children = DynamicSupervisor.which_children(Kinoko.Elm.Supervisor)
        refute Enum.any?(children, fn {_, child, _, _} -> child in [old, :restarting] end)
        assert Process.whereis(Kinoko.Elm.Supervisor) == sup
        assert pid(u) == nil

        # The next call boots it itself and reports why it cannot.
        assert {:error, %{code: "internal", message: message}} = Universe.symbols(u)
        assert message =~ cid
      end)
    end

    test "a boot the database fails is unavailable, not internal", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      stop(u)

      # Inside the test's transaction, so rolled back with it: the boot read
      # fails with a Postgrex.Error, as it would against a broken database.
      Repo.query!("ALTER TABLE elm_states RENAME TO elm_states_away")

      capture_log(fn ->
        assert {:error, %{code: "unavailable", message: message}} = Universe.symbols(u)
        assert message =~ "database"
      end)

      Repo.query!("ALTER TABLE elm_states_away RENAME TO elm_states")
      assert ["A.g"] = Enum.map(Universe.symbols(u), & &1.symbol)
    end

    test "CAS text that does not parse refuses boot naming the CID", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      [%{cid: cid}] = Universe.symbols(u)
      stop(u)
      Repo.update_all(from(d in "declarations", where: d.cid == ^cid), set: [text: "def ((("])

      capture_log(fn ->
        assert {:error, %{code: "internal", message: message}} = Universe.history(u)
        assert message =~ cid
        assert message =~ "parse"
      end)
    end

    # 4. A long eval at the same time as a stage. The eval's worker is seen
    # running the image's code before the stage starts, and still running
    # it after the stage returned: the stage provably happened during it.
    test "a long eval does not block a concurrent stage", %{u: u} do
      {:promoted, _} = Universe.stage(u, "loop", "def A.loop(n : Int) : Int do A.loop(n + 1) end")
      # Compile the image up front, so the eval below is all running.
      {:ok, 1, _} = Universe.eval(u, "1", [])
      {:ok, hash, _sigs} = Kinoko.PersistentElmGenServer.call(key(u), :image_key)
      {:ok, %{module: module}} = Exec.loaded(hash)

      eval = Task.async(fn -> Universe.eval(u, "A.loop(0)", timeout: 2_000) end)
      worker = await_running(module)

      {us, result} = :timer.tc(fn -> Universe.stage(u, "p1", @g) end)
      assert {:promoted, ["p1"]} = result
      assert us < 1_000_000

      assert running?(worker, module), "the eval finished before the stage returned"
      assert Task.yield(eval, 0) == nil

      assert {:error, %{code: "timeout"}} = Task.await(eval, 10_000)
    end
  end

  describe "apply" do
    test "applies a closure the image made and a constructor fun", %{u: u} do
      {:promoted, _} = Universe.stage(u, "c", @counter)

      {:promoted, _} =
        Universe.stage(u, "add", """
        def M.adder(n : Int) : (Int -> Int) do
          fn (x : Int) -> x + n end
        end
        """)

      assert {:ok, add2, _} = Universe.call(u, "M.adder", [2], [])
      assert {:ok, 5} = Universe.apply(u, add2, [3], [])

      assert {:ok, ctor, _} = Universe.eval(u, "Counter.Msg.Add", [])
      assert {:ok, expected, _} = Universe.eval(u, "Counter.Msg.Add(4)", [])
      assert {:ok, ^expected} = Universe.apply(u, ctor, [4], [])
    end

    test "is bounded and refuses what it cannot apply", %{u: u} do
      {:promoted, _} =
        Universe.stage(u, "f", """
        def M.spin() : (Int -> Int) do
          fn (x : Int) -> M.loop(x) end
        end

        def M.loop(n : Int) : Int do
          M.loop(n + 1)
        end
        """)

      {:ok, spin, _} = Universe.call(u, "M.spin", [], [])
      assert {:error, %{code: "timeout"}} = Universe.apply(u, spin, [0], timeout: 100)
      assert {:error, %{code: "runtime"}} = Universe.apply(u, spin, [1, 2], [])
      assert {:error, %{code: "runtime"}} = Universe.apply(u, :not_a_fun, [], [])
      assert {:error, :no_such_universe} = Universe.apply("nope-apply", spin, [0], [])
    end

    test "a closure of an unloaded image answers unloaded", %{u: u} do
      {:promoted, _} =
        Universe.stage(u, "f", "def M.k() : (Int -> Int) do\n  fn (x : Int) -> x end\nend")

      {:ok, k, _} = Universe.call(u, "M.k", [], [])
      {:promoted, _} = Universe.stage(u, "g", @g)
      {:ok, old} = Universe.at(u, 1)
      :ok = Exec.unload(Exec.loaded(old.hash) |> elem(1))

      assert {:error, %{code: "unloaded"}} = Universe.apply(u, k, [1], [])
    end
  end

  describe "apps and routes" do
    @forum File.read!("test/fixtures/yabu/forum.yabu")

    test "list the committed apps and route tables", %{u: u} do
      assert [] = Universe.apps(u)
      assert %{} == Universe.routes(u)

      {:promoted, _} = Universe.stage(u, "forum", @forum)
      assert ["Forum.Post", "Forum.Settings", "Forum.Threads"] = Universe.apps(u)

      assert %{"Forum" => [%{app: "Forum.Threads"}, post, %{app: "Forum.Settings"}]} =
               Universe.routes(u)

      assert %{segments: [{:lit, "post"}, {:param, "id"}], params: [{"id", "Uuid"}]} = post
      assert {:error, :no_such_universe} = Universe.apps("nope-apps")
      assert {:error, :bad_name} = Universe.routes("Bad Name")
    end
  end

  describe "subscribe" do
    test "a promotion is broadcast after it is stored; a staged-only patch is not", %{u: u} do
      assert :ok = Universe.subscribe(u)

      {:promoted, _} = Universe.stage(u, "p1", @g)
      assert_receive {:committed, ^u, %{commit: 1, image_hash: h1}}
      assert is_binary(h1)
      assert stored_commits(u) == 1

      {:staged, _} = Universe.stage(u, "wip", @f <> "\n\ndef A.f2() : Int do\n  A.nope()\nend")
      :ok = Universe.unstage(u, "wip")
      refute_receive {:committed, _, _}, 50

      {:promoted, _} = Universe.stage(u, "p2", "def A.g() : Int do\n  2\nend")
      assert_receive {:committed, ^u, %{commit: 2, image_hash: h2}}
      assert h2 != h1
      assert stored_commits(u) == 2

      assert {:error, :no_such_universe} = Universe.subscribe("nope-sub")
    end
  end

  describe "current" do
    test "runs every call on the image it resolved, with no further round trip", %{u: u} do
      assert {:promoted, _} = Universe.stage(u, "p", @g)
      assert {:ok, current} = Universe.current(u)
      assert {:ok, 1, _} = Universe.call(current, "A.g", [])

      assert {:promoted, _} = Universe.stage(u, "p2", "def A.g() : Int do\n  2\nend")
      assert {:ok, 1, _} = Universe.call(current, "A.g", [])
      assert {:ok, 2, _} = Universe.call(u, "A.g", [])

      # The CodeDb is not consulted: the handle runs with it stopped.
      stop(u)
      assert {:ok, 1, _} = Universe.call(current, "A.g", [])
    end

    test "errors as call/4 does", %{u: _u} do
      assert {:error, :no_such_universe} =
               Universe.current("nope-#{System.unique_integer([:positive])}")
    end
  end

  describe "at" do
    test "answers with a past commit's code after head changed", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      {:promoted, _} = Universe.stage(u, "p2", "def A.g() : Int do\n  5\nend")

      assert {:ok, one} = Universe.at(u, 1)
      assert {:ok, two} = Universe.at(u, 2)
      assert {:ok, 1, {:named, "Int"}} = Universe.call(one, "A.g", [], [])
      assert {:ok, 5, _} = Universe.call(two, "A.g", [], [])
      assert {:ok, 5, _} = Universe.call(u, "A.g", [], [])
      assert {:ok, 1, _} = Universe.eval(one, "A.g()", [])

      # Cached: the same handle again.
      assert {:ok, ^one} = Universe.at(u, 1)
    end

    test "a reused name with another history is rebuilt, never served stale", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      {:ok, old} = Universe.at(u, 1)
      assert {:ok, 1, _} = Universe.call(old, "A.g", [], [])

      # The name is used again from scratch (as after a database reset).
      stop(u)
      Repo.query!("DELETE FROM elm_states WHERE key = $1", [key(u)])
      Repo.query!("DELETE FROM universes WHERE name = $1", [u])
      :ok = Universe.create(u)
      {:promoted, _} = Universe.stage(u, "p1", "def A.g() : Int do\n  7\nend")

      assert {:ok, fresh} = Universe.at(u, 1)
      assert fresh != old
      assert {:ok, 7, _} = Universe.call(fresh, "A.g", [], [])

      # The old view, its image unloaded, is not rebuilt from the new history.
      {:ok, image} = Exec.loaded(old.hash)
      :ok = Exec.unload(image)
      assert {:error, %{code: "no_such_commit"}} = Universe.call(old, "A.g", [], [])
    end

    test "survives its image being unloaded", %{u: u} do
      {:promoted, _} = Universe.stage(u, "p1", @g)
      {:ok, one} = Universe.at(u, 1)
      {:ok, image} = Exec.loaded(one.hash)
      :ok = Exec.unload(image)
      assert {:ok, 1, _} = Universe.call(one, "A.g", [], [])
    end

    test "apply, apps and routes take a handle", %{u: u} do
      {:promoted, _} = Universe.stage(u, "forum", @forum)
      {:promoted, _} = Universe.stage(u, "counter", @counter)
      {:ok, one} = Universe.at(u, 1)

      assert ["Forum.Post", "Forum.Settings", "Forum.Threads"] = Universe.apps(one)
      assert "Counter" in Universe.apps(u)
      assert %{"Forum" => [_, _, _]} = Universe.routes(one)

      {:ok, ctor, _} = Universe.eval(one, "Forum.Post.Msg.Draft", [])
      {:ok, expected, _} = Universe.eval(one, ~s|Forum.Post.Msg.Draft("hi")|, [])
      assert {:ok, ^expected} = Universe.apply(one, ctor, ["hi"], [])
      assert {:error, %{code: "unbound"}} = Universe.eval(one, "Counter.init()", [])
    end

    test "an out-of-range commit is no_such_commit", %{u: u} do
      assert {:error, %{code: "no_such_commit"}} = Universe.at(u, 1)
      {:promoted, _} = Universe.stage(u, "p1", @g)

      for n <- [0, -1, 2, "1", nil] do
        assert {:error, %{code: "no_such_commit", message: _}} = Universe.at(u, n)
      end

      assert {:error, :no_such_universe} = Universe.at("nope-at", 1)
    end

    test "a degraded universe still opens an older healthy commit", %{u: u} do
      store_commits(u, [{"ok", @g}, {"bad", @f <> "\n\ndef A.h() : Int do\n  A.nope()\nend"}])

      capture_log(fn -> assert {:degraded, _} = Universe.health(u) end)
      assert {:ok, one} = Universe.at(u, 1)
      assert {:ok, 1, _} = Universe.call(one, "A.g", [], [])
      assert {:error, %{code: "degraded"}} = Universe.at(u, 2)
    end
  end

  defp stored_commits(u) do
    {:ok, row} = Kinoko.Elm.Store.latest(key(u))
    %{commits: commits} = :erlang.binary_to_term(row.state)
    length(commits)
  end
end
