defmodule Kinoko.ReplTest do
  use Kinoko.DataCase, async: false

  import ExUnit.CaptureIO
  import Kinoko.UniverseHelpers

  alias Kinoko.Repl, as: Y
  alias Kinoko.Universe

  @counter "test/fixtures/yabu/counter.yabu"

  setup do
    name = fresh_universe("repl")
    capture_io(fn -> assert Y.use(name) == :ok end)
    %{u: name}
  end

  test "the walkthrough: load, init, update, view" do
    out = capture_io(fn -> assert Y.load(@counter) == :ok end)
    assert out =~ "promoted: counter"

    out = capture_io(fn -> Y.eval("Counter.init()") end)
    assert out =~ "(%Counter.Model{count: 0}, Cmd.none()) : (Counter.Model, Cmd<Counter.Msg>)"

    out =
      capture_io(fn ->
        {{:rec, "Counter.Model", %{"count" => 6}}, _cmd} =
          Y.eval("Counter.update(Counter.Msg.Add(5), %Counter.Model{count: 1})")
      end)

    assert out =~ "(%Counter.Model{count: 6}, Cmd.none())"

    out = capture_io(fn -> Y.eval("Counter.view(%Counter.Model{count: 2})") end)
    assert out =~ "<div class=\"counter\">"
    assert out =~ ": Html<Counter.Msg>"
  end

  test "a broken patch stays staged with readable reasons; restaging the id fixes it" do
    capture_io(fn -> Y.load(@counter) end)
    broken = "def Counter.double(m : Counter.Model) : Int do Counter.twice(m.count) end"

    out = capture_io(fn -> assert {:staged, [_ | _]} = Y.load(broken, id: "double") end)
    assert out =~ "staged: double"
    assert out =~ "Counter.double: [unbound]"

    fixed = "def Counter.twice(n : Int) : Int do n * 2 end\n" <> broken

    out = capture_io(fn -> assert Y.load(fixed, id: "double") == :ok end)
    assert out =~ "promoted: double"

    out = capture_io(fn -> assert Y.eval("Counter.double(%Counter.Model{count: 21})") == 42 end)
    assert out =~ "42 : Int"
  end

  test "source without an id gets repl-N ids" do
    out = capture_io(fn -> Y.load("def A.one() : Int do 1 end") end)
    assert out =~ "promoted: repl-1"
    out = capture_io(fn -> Y.load("def A.two() : Int do 2 end") end)
    assert out =~ "promoted: repl-2"
  end

  test "call, test, symbols, read, history, unstage, reset" do
    capture_io(fn ->
      Y.load("""
      def A.one() : Int do 1 end
      deftest A.t do
        always(A.one() == 1)
      end
      """)
    end)

    assert capture_io(fn -> assert Y.call("A.one", []) == 1 end) =~ "1 : Int"
    assert capture_io(fn -> assert Y.test("A.t") == :ok end) =~ "A.t: ok"
    assert capture_io(fn -> Y.symbols() end) =~ "A.one() : Int"
    assert capture_io(fn -> assert Y.read("A.one") == :ok end) =~ "def A.one"
    assert capture_io(fn -> assert Y.read("A.nope") == :error end) =~ "no committed symbol"
    assert [%{ids: ["repl-1"]}] = Y.history()

    capture_io(fn -> Y.load("def A.bad() : Int do A.missing() end", id: "bad") end)
    assert capture_io(fn -> assert Y.unstage("bad") == :ok end) =~ "unstaged: bad"

    assert capture_io(fn -> assert Y.unstage("bad") == :not_found end) =~
             "nothing staged under bad"
  end

  test "universes: create, use, list; a fresh universe starts empty", %{u: u} do
    capture_io(fn -> Y.load(@counter) end)
    assert Y.current() == u

    other = "repl-other-#{System.unique_integer([:positive])}"
    stop_on_exit(other)
    assert capture_io(fn -> assert Y.create(other) == :ok end) =~ "created: #{other}"
    assert capture_io(fn -> assert {:error, :exists} = Y.create(other) end) =~ "already exists"

    assert capture_io(fn -> assert {:error, :bad_name} = Y.create("Bad Name") end) =~
             "bad universe"

    out = capture_io(fn -> Y.universes() end)
    assert out =~ "#{u} (current)\n"
    assert out =~ "#{other}\n"

    assert capture_io(fn -> assert Y.use(other) == :ok end) =~ "using: #{other}"
    assert Y.current() == other
    assert Y.history() == []
    assert capture_io(fn -> assert {:error, _} = Y.eval("Counter.init()") end) =~ "error: ["

    # The first universe kept its state.
    capture_io(fn -> Y.use(u) end)
    assert [%{ids: ["counter"]}] = Y.history()
  end

  test "use of an unknown or bad name says so and stays put", %{u: u} do
    out = capture_io(fn -> assert Y.use("nope-nope") == {:error, :no_such_universe} end)
    assert out == "error: no such universe: nope-nope\n"
    out = capture_io(fn -> assert Y.use(:main) == {:error, :bad_name} end)
    assert out =~ "bad universe name"
    assert Y.current() == u
  end

  test "the state is the universe's: killing its CodeDb mid-session loses nothing", %{u: u} do
    capture_io(fn -> Y.load(@counter) end)
    capture_io(fn -> assert Y.load("def A.one() : Int do 1 end") == :ok end)

    pid = pid(u)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    assert capture_io(fn -> assert Y.eval("A.one() + 1") == 2 end) =~ "2 : Int"
    out = capture_io(fn -> Y.eval("Counter.init()") end)
    assert out =~ "%Counter.Model{count: 0}"
    assert [%{ids: ["counter"]}, %{ids: ["repl-1"]}] = Y.history()

    # And the next anonymous id continues the numbering.
    assert capture_io(fn -> Y.load("def A.two() : Int do 2 end") end) =~ "promoted: repl-2"
  end

  test "a universe that no longer exists is reported by every command, not a crash" do
    Process.put({Kinoko.Repl, :universe}, "gone-#{System.unique_integer([:positive])}")

    for fun <- [
          fn -> Y.test("A.t") end,
          fn -> Y.eval("1") end,
          fn -> Y.call("A.one", []) end,
          fn -> Y.symbols() end,
          fn -> Y.read("A.one") end,
          fn -> Y.unstage("x") end,
          fn -> Y.history() end,
          fn -> Y.load("def A.one() : Int do 1 end") end
        ] do
      out = capture_io(fn -> assert {:error, :no_such_universe} = fun.() end)
      assert out =~ "no such universe"
    end
  end

  test "main works out of the box" do
    :ok = Universe.Registry.ensure_main()
    on_exit(fn -> stop("main") end)
    Process.delete({Kinoko.Repl, :universe})
    assert Y.current() == "main"
    out = capture_io(fn -> assert Y.load("def Repltest.one() : Int do 1 end") == :ok end)
    assert out =~ "promoted: repl-"
    assert capture_io(fn -> assert Y.eval("Repltest.one()") == 1 end) =~ "1 : Int"
  end

  test "errors print readably, the message once" do
    capture_io(fn -> Y.load(@counter) end)
    out = capture_io(fn -> assert {:error, _} = Y.eval("Counter.nope()") end)
    assert out =~ "error: ["
    out = capture_io(fn -> assert {:error, _} = Y.eval("1 +") end)
    assert out =~ "[parse]"
    # One reason, the message itself: printed once.
    assert [_] = String.split(out, "\n", trim: true)

    out = capture_io(fn -> assert {:error, %{code: "runtime"}} = Y.eval("1 / 0") end)
    assert out == "error: [runtime] division by zero\n"
  end

  test "last is the last value eval or call computed; outside iex they return it too" do
    assert Y.last() == nil
    capture_io(fn -> Y.load(@counter) end)
    capture_io(fn -> assert Y.eval("1 + 2") == 3 end)
    assert Y.last() == 3
    capture_io(fn -> assert Y.call("Counter.init", []) == Y.last() end)
    assert {{:rec, "Counter.Model", %{"count" => 0}}, {:cmd, :none}} = Y.last()
    # An error leaves it.
    capture_io(fn -> Y.eval("1 / 0") end)
    assert {{:rec, "Counter.Model", _}, _} = Y.last()
  end

  test "a path that names no file is said so, and nothing is staged" do
    for path <- ["test/fixtures/yabu/countr.yabu", "counter.yabu", "notes.txt", "missing"] do
      out = capture_io(fn -> assert Y.load(path) == {:error, :enoent} end)
      assert out == "no such file: #{path}\n"
    end

    out = capture_io(fn -> assert Y.load("test/fixtures/yabu") == {:error, :eisdir} end)
    assert out =~ "test/fixtures/yabu is a directory"
    assert Y.history() == []
    assert Universe.staged(Y.current()) == []
  end

  test "health says healthy, or degraded with the reasons", %{u: u} do
    assert capture_io(fn -> assert Y.health() == :ok end) =~ "ok: #{u} is healthy"

    stop(u)
    store_commit(u, "def A.f() : Int do\n  A.g()\nend")

    ExUnit.CaptureLog.capture_log(fn ->
      out = capture_io(fn -> assert {:degraded, [%{name: "A.f"}]} = Y.health() end)
      assert out =~ "degraded: #{u}"
      assert out =~ "A.f: [unbound]"
    end)
  end
end
