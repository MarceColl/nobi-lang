defmodule Kinoko.ReplTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kinoko.Repl, as: Y

  @counter "test/fixtures/yabu/counter.yabu"

  setup do
    Y.reset()
    :ok
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
    assert capture_io(fn -> assert Y.unstage("bad") == true end) =~ "unstaged: bad"
    assert capture_io(fn -> assert Y.unstage("bad") == false end) =~ "nothing staged under bad"

    Y.reset()
    assert Y.history() == []
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
    assert Kinoko.Lang.staged(Y.u()) == %{}
  end
end
