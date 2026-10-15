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

    # 4. A long eval at the same time as a stage.
    test "a long eval does not block a concurrent stage", %{u: u} do
      {:promoted, _} = Universe.stage(u, "loop", "def A.loop(n : Int) : Int do A.loop(n + 1) end")
      # Compile the image up front, so the eval below is all running.
      {:ok, 1, _} = Universe.eval(u, "1", [])

      eval = Task.async(fn -> Universe.eval(u, "A.loop(0)", timeout: 2_000) end)
      Process.sleep(100)

      {us, result} = :timer.tc(fn -> Universe.stage(u, "p1", @g) end)
      assert {:promoted, ["p1"]} = result
      assert us < 1_000_000
      assert Task.yield(eval, 0) == nil

      assert {:error, %{code: "timeout"}} = Task.await(eval, 10_000)
    end
  end
end
