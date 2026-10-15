defmodule Kinoko.ExecTest do
  # Loads, caches and unloads image modules, which are global: not async.
  use ExUnit.Case, async: false

  alias Kinoko.Exec
  alias Kinoko.Lang
  alias Kinoko.Lang.Rt

  doctest Kinoko.Exec

  # The semantic tests of kinoko-next `tests/interp_eval.rs`, run through
  # `Exec`, then what only the BEAM has: the worker's limits and the image
  # cache. Rust's step-budget and depth tests have no BEAM form as written;
  # their runaway programs end here in `"timeout"` or `"heap"`.

  defp universe(""), do: Lang.snapshot(Lang.new())

  defp universe(src) do
    {u, r} = Lang.stage(Lang.new(), "p", src)
    assert {:promoted, _} = r, inspect(r)
    Lang.snapshot(u)
  end

  defp value_in(src, expr) do
    case Exec.eval(universe(src), expr) do
      {:ok, v, _type} -> v
      other -> flunk("#{expr}: #{inspect(other)}")
    end
  end

  defp value(expr), do: value_in("", expr)

  defp error_in(src, expr) do
    assert {:error, %{code: "runtime", message: m}} = Exec.eval(universe(src), expr)
    m
  end

  defp call(src_or_u, name, args, opts \\ [])

  defp call(src, name, args, opts) when is_binary(src),
    do: call(universe(src), name, args, opts)

  defp call(u, name, args, opts) do
    case Exec.call(u, name, args, opts) do
      {:ok, v} -> {:ok, v}
      {:error, %{code: "runtime", message: m}} -> {:error, m}
      {:error, e} -> {:error, e}
    end
  end

  defp rec(model, fields), do: {:rec, model, Map.new(fields)}
  defp var(owner, variant, args \\ []), do: {:var, owner, variant, args}
  defp some(v), do: var("Option", "Some", [v])
  defp none, do: var("Option", "None")
  defp text(s), do: var("Html", "Text", [s])
  defp element(tag, attrs, children), do: var("Html", "Element", [tag, attrs, children])

  # The pid of every process the calling process spawns while `f` runs, and
  # `f`'s result. (A process cannot be its own tracer: a helper collects.)
  defp spawned_during(f) do
    me = self()
    tracer = spawn_link(fn -> collect_spawns([]) end)
    1 = :erlang.trace(me, true, [:procs, {:tracer, tracer}])

    result =
      try do
        f.()
      after
        :erlang.trace(me, false, [:procs])
      end

    ref = :erlang.trace_delivered(me)

    receive do
      {:trace_delivered, ^me, ^ref} -> :ok
    end

    send(tracer, {:spawned, me})

    receive do
      {:spawned, pids} -> {result, pids}
    end
  end

  # As `spawned_during/1`, for the processes `pid` spawns.
  defp spawned_by(pid, f) do
    tracer = spawn_link(fn -> collect_spawns([]) end)
    1 = :erlang.trace(pid, true, [:procs, {:tracer, tracer}])
    result = f.()
    me = self()
    send(tracer, {:spawned, me})

    receive do
      {:spawned, pids} -> {result, pids}
    end
  end

  # Returns once some process runs `module`'s code.
  defp wait_until_running(module, tries \\ 500) do
    running? =
      Enum.any?(Process.list(), fn pid ->
        match?({:current_function, {^module, _, _}}, Process.info(pid, :current_function))
      end)

    cond do
      running? ->
        :ok

      tries == 0 ->
        flunk("nothing runs #{module}")

      true ->
        Process.sleep(10)
        wait_until_running(module, tries - 1)
    end
  end

  # `pid` is dead, or dies within a second.
  defp assert_gone(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  defp collect_spawns(acc) do
    receive do
      {:trace, _, :spawn, pid, _} -> collect_spawns([pid | acc])
      {:spawned, to} -> send(to, {:spawned, Enum.reverse(acc)})
      _ -> collect_spawns(acc)
    end
  end

  describe "literals, names and collections" do
    test "literals are themselves" do
      assert value("42") == 42
      assert value("-7") == -7
      assert value(~S("hi")) == "hi"
      assert value("true") == true
    end

    test "a local is its binding" do
      assert call("def A.id(n : Int) : Int do n end", "A.id", [3]) == {:ok, 3}
    end

    test "a def used as a value is the def's function" do
      src = "def A.double(n : Int) : Int do n * 2 end"
      u = universe(src)
      {:ok, image} = Exec.load(u)
      {f, 1} = image.names["A.double"]
      assert {:ok, fun, {:arrow, _, _}} = Exec.eval(u, "A.double")
      assert fun == Function.capture(image.module, f, 1)
    end

    test "variants without arguments are built; a constructor alone is a function" do
      assert value_in("deftype A.Color do Red | Green end", "A.Color.Red") ==
               var("A.Color", "Red")

      assert value("[Option.None, Option.Some(1)]") == [none(), some(1)]

      ctor = value_in("deftype A.Shape do Circle(Int) | Dot end", "A.Shape.Circle")
      assert ctor == Rt.ctor("A.Shape", "Circle", 1)
    end

    test "lists, maps and tuples hold their items; a repeated key keeps the last value" do
      assert value("[1, 2, 3]") == [1, 2, 3]
      assert value(~S(%{"b" => 2, "a" => 1})) == %{"a" => 1, "b" => 2}
      assert value(~S|(1, "x", true)|) == {1, "x", true}
      assert value(~S(%{"a" => 1, "a" => 2})) == %{"a" => 2}
    end
  end

  describe "operators" do
    test "arithmetic, comparison and concatenation" do
      for {expr, v} <- [
            {"1 + 2 * 3", 7},
            {"10 - 4 - 3", 3},
            {"7 / 2", 3},
            {"2 < 3", true},
            {"3 <= 3", true},
            {"4 > 5", false},
            {"5 >= 6", false},
            {~S("ab" ++ "cd"), "abcd"},
            {"1 != 2", true},
            {~S("a" == "a"), true},
            {"not (1 < 2)", false},
            {"not false", true},
            {"-(2 + 3)", -5}
          ] do
        assert value(expr) == v, expr
      end
    end

    test "and/or evaluate their right side only when it decides" do
      assert value("false and 1 / 0 == 0") == false
      assert value("true or 1 / 0 == 0") == true
      assert value("true and 1 < 2") == true
      assert value("false or 2 < 1") == false
      assert error_in("", "true and 1 / 0 == 0") == "division by zero"
    end

    test "equality is structural (TS codegen.test.ts)" do
      src = """
      defmodel E.P do x : Int end
      def E.same(a : E.P, b : E.P) : Bool do a == b end
      def E.lists(a : List<Int>, b : List<Int>) : Bool do a == b end
      """

      u = universe(src)
      p = &rec("E.P", [{"x", &1}])
      assert call(u, "E.same", [p.(1), p.(1)]) == {:ok, true}
      assert call(u, "E.same", [p.(1), p.(2)]) == {:ok, false}
      assert call(u, "E.lists", [[1, 2], [1, 2]]) == {:ok, true}
      assert call(u, "E.lists", [[1], [1, 2]]) == {:ok, false}
    end

    test "effects differing only by the model they read are unequal" do
      src = """
      defmodel E.A do n : Int end
      defmodel E.B do n : Int end
      deftype E.Msg do Rows(List<E.A>) end
      def E.same(a : Cmd<E.Msg>, b : Cmd<E.Msg>) : Bool do a == b end
      """

      u = universe(src)
      read = &{:cmd, {:effect, "Cmd.store.list", &1, [Rt.ctor("E.Msg", "Rows", 1)]}}
      assert call(u, "E.same", [read.("E.A"), read.("E.A")]) == {:ok, true}
      assert call(u, "E.same", [read.("E.A"), read.("E.B")]) == {:ok, false}
      assert call(u, "E.same", [read.("E.A"), read.(nil)]) == {:ok, false}
    end

    test "division truncates toward zero; by zero and overflow are errors" do
      u = universe("def N.half(x : Int) : Int do x / 2 end")
      assert call(u, "N.half", [5]) == {:ok, 2}
      assert call(u, "N.half", [-5]) == {:ok, -2}

      u =
        universe("""
        def N.add(x : Int, y : Int) : Int do x + y end
        def N.sub(x : Int, y : Int) : Int do x - y end
        def N.mul(x : Int, y : Int) : Int do x * y end
        def N.div(x : Int, y : Int) : Int do x / y end
        def N.neg(x : Int) : Int do -x end
        """)

      max = 9_223_372_036_854_775_807
      min = -max - 1
      assert call(u, "N.div", [5, 0]) == {:error, "division by zero"}

      for {name, args} <- [
            {"N.add", [max, 1]},
            {"N.sub", [min, 1]},
            {"N.mul", [max, 2]},
            {"N.div", [min, -1]},
            {"N.neg", [min]}
          ] do
        assert call(u, name, args) == {:error, "integer overflow"}, name
      end

      assert call(u, "N.neg", [max]) == {:ok, -max}
    end
  end

  @boxes """
  deftype A.Box do Full(Int) | Empty end
  def A.double(n : Int) : Int do n * 2 end
  def A.twice(f : (Int -> Int), n : Int) : Int do f(f(n)) end
  def A.adder(n : Int) : (Int -> Int) do
    fn (x : Int) -> x + n end
  end
  def A.add_all(xs : List<Int>, n : Int) : List<Int> do
    List.map(xs, fn (x : Int) -> x + n end)
  end
  def A.apply(f : (Int -> Int), x : Int) : Int do f(x) end
  def A.show(f : (Int -> String), x : Int) : String do f(x) end
  def A.boxed(f : (Int -> A.Box), x : Int) : A.Box do f(x) end
  def A.box_all(xs : List<Int>) : List<A.Box> do List.map(xs, A.Box.Full) end
  """

  describe "calls and functions" do
    test "calls of defs, local functions, constructors and the stdlib" do
      assert value_in(@boxes, "A.double(4)") == 8
      assert value_in(@boxes, "A.twice(A.double, 3)") == 12
      assert value_in(@boxes, "A.Box.Full(7)") == var("A.Box", "Full", [7])
      assert value_in(@boxes, "List.map([1, 2], A.double)") == [2, 4]
      assert value_in(@boxes, "String.from_int(42)") == "42"
    end

    test "a closure captures the locals in scope where it is made" do
      assert call(@boxes, "A.add_all", [[1, 2], 10]) == {:ok, [11, 12]}
      assert value_in(@boxes, "A.twice(fn (x : Int) -> x * x end, 3)") == 81
    end

    test "a function value is applied later, whatever its form" do
      u = universe(@boxes)
      {:ok, add5} = call(u, "A.adder", [5])
      assert is_function(add5, 1)
      assert call(u, "A.apply", [add5, 1]) == {:ok, 6}
      assert call(u, "A.apply", [add5, 2]) == {:ok, 7}

      {:ok, double, _} = Exec.eval(u, "A.double")
      assert call(u, "A.apply", [double, 4]) == {:ok, 8}
      {:ok, from_int, _} = Exec.eval(u, "String.from_int")
      assert call(u, "A.show", [from_int, 4]) == {:ok, "4"}
      full = Rt.ctor("A.Box", "Full", 1)
      assert call(u, "A.boxed", [full, 3]) == {:ok, var("A.Box", "Full", [3])}

      assert call(u, "A.box_all", [[1, 2]]) ==
               {:ok, [var("A.Box", "Full", [1]), var("A.Box", "Full", [2])]}
    end

    test "a def called with the wrong arguments, or unknown, is an error" do
      u = universe(@boxes)
      assert call(u, "A.double", []) == {:error, "`A.double` takes 1 argument(s), got 0"}
      assert call(u, "A.nothing", []) == {:error, "no def named `A.nothing`"}
      # Only the image's defs are called by name, as Rust's `call`.
      assert call(u, "String.from_int", [1]) == {:error, "no def named `String.from_int`"}
    end

    test "call takes a loaded image as well as a universe" do
      {:ok, image} = Exec.load(universe(@boxes))
      assert Exec.call(image, "A.double", [21]) == {:ok, 42}
    end
  end

  @points """
  defmodel A.P do
    x : Int
    name : String
  end
  defmodel A.Row do
    id : Uuid
    text : String
  end
  def A.make() : A.P do %A.P{x: 1, name: "p"} end
  def A.moved(p : A.P) : A.P do %A.P{p | x: p.x + 1} end
  def A.row() : A.Row do %A.Row{text: "t"} end
  """

  @patterns """
  deftype A.T do Leaf | Node(A.T, Int) end
  def A.describe(t : A.T) : String do
    case t do
      A.T.Leaf -> "leaf"
      A.T.Node(A.T.Leaf, 0) -> "zero on a leaf"
      A.T.Node(A.T.Leaf, n) -> String.from_int(n)
      A.T.Node(_, _) -> "deeper"
    end
  end
  def A.word(n : Int) : String do
    case n do
      0 -> "zero"
      -1 -> "minus one"
      other -> String.from_int(other)
    end
  end
  def A.yes(b : Bool) : String do
    case b do
      true -> "yes"
      _ -> "no"
    end
  end
  def A.greet(s : String) : String do
    case s do
      "hi" -> "hello"
      _ -> s
    end
  end
  def A.pair(p : (Bool, Option<Int>)) : String do
    case p do
      (true, Option.Some(0)) -> "true and zero"
      (true, _) -> "true"
      (false, Option.Some(n)) -> String.from_int(n)
      (_, Option.None) -> "none"
    end
  end
  def A.nested(p : ((Int, String), Option<(Int, Int)>)) : String do
    case p do
      ((0, "a"), Option.Some((x, y))) -> String.from_int(x + y)
      ((n, _), Option.Some((_, 1))) -> String.from_int(n)
      ((n, s), _) -> s
    end
  end
  """

  describe "records, case, if and blocks" do
    test "a record is built, updated and read; a Uuid id is the store's to mint" do
      u = universe(@points)
      made = rec("A.P", [{"x", 1}, {"name", "p"}])
      assert call(u, "A.make", []) == {:ok, made}
      assert call(u, "A.moved", [made]) == {:ok, rec("A.P", [{"x", 2}, {"name", "p"}])}
      assert value_in(@points, "A.make().name") == "p"
      assert call(u, "A.row", []) == {:ok, rec("A.Row", [{"text", "t"}])}
    end

    test "case takes the first arm that matches, every pattern form" do
      u = universe(@patterns)
      leaf = var("A.T", "Leaf")
      node = &var("A.T", "Node", [&1, &2])

      for {name, arg, want} <- [
            {"A.describe", leaf, "leaf"},
            {"A.describe", node.(leaf, 0), "zero on a leaf"},
            {"A.describe", node.(leaf, 7), "7"},
            {"A.describe", node.(node.(leaf, 1), 0), "deeper"},
            {"A.word", 0, "zero"},
            {"A.word", -1, "minus one"},
            {"A.word", 5, "5"},
            {"A.yes", true, "yes"},
            {"A.yes", false, "no"},
            {"A.greet", "hi", "hello"},
            {"A.greet", "yo", "yo"},
            {"A.pair", {true, some(0)}, "true and zero"},
            {"A.pair", {true, some(5)}, "true"},
            {"A.pair", {true, none()}, "true"},
            {"A.pair", {false, some(7)}, "7"},
            {"A.pair", {false, none()}, "none"},
            {"A.nested", {{0, "a"}, some({2, 3})}, "5"},
            {"A.nested", {{0, "a"}, some({2, 1})}, "3"},
            {"A.nested", {{4, "b"}, some({9, 1})}, "4"},
            {"A.nested", {{4, "bc"}, some({9, 2})}, "bc"},
            {"A.nested", {{0, "a"}, none()}, "a"}
          ] do
        assert call(u, name, [arg]) == {:ok, want}, "#{name}(#{inspect(arg)})"
      end
    end

    test "a case no arm matches is an error" do
      assert call(@patterns, "A.describe", [var("A.T", "Stranger")]) ==
               {:error, "no case arm matched"}
    end

    test "if evaluates only the branch taken" do
      assert value(~S|if 1 < 2 do "a" else "b" end|) == "a"
      assert value(~S|if 2 < 1 do "a" else "b" end|) == "b"
      assert value("if true do 1 else 1 / 0 end") == 1
    end

    test "a block binds in order and its bindings stay inside" do
      src = """
      def A.f(n : Int) : Int do
        x = n + 1
        y = do
          x = 100
          x * 2
        end
        x + y
      end
      """

      assert call(src, "A.f", [1]) == {:ok, 202}
    end

    test "a closure holds the bindings in scope where it is made" do
      src = """
      def A.later() : List<Int> do
        y = 5
        do
          fs = [fn (n : Int) -> n + y end]
          y = 100
          List.map(fs, fn (f : (Int -> Int)) -> f(1) end)
        end
      end
      def A.early() : List<Int> do
        y = 5
        do
          rs = List.map([fn (n : Int) -> n + y end], fn (f : (Int -> Int)) -> f(1) end)
          y = 100
          rs
        end
      end
      """

      u = universe(src)
      assert call(u, "A.later", []) == {:ok, [6]}
      assert call(u, "A.early", []) == {:ok, [6]}
    end
  end

  describe "JSX" do
    test "builds Html with attributes as pairs and children as Html" do
      src = """
      deftype A.Msg do Inc | Set(String) end
      def A.view(n : Int, items : List<String>) : Html<A.Msg> do
        <div class="box" n={n}>
          Count:
          {n}
          {"!"}
          <button on-click={A.Msg.Inc}>+</button>
          <input on-change={A.Msg.Set} />
          {List.map(items, fn (s : String) -> <li>{s}</li> end)}
        </div>
      end
      """

      li = &element("li", [], [text(&1)])

      want =
        element("div", [{"class", "box"}, {"n", 3}], [
          text("Count:"),
          text("3"),
          text("!"),
          element("button", [{"on-click", var("A.Msg", "Inc")}], [text("+")]),
          element("input", [{"on-change", Rt.ctor("A.Msg", "Set", 1)}], []),
          li.("a"),
          li.("b")
        ])

      assert call(src, "A.view", [3, ["a", "b"]]) == {:ok, want}
    end
  end

  @math """
  def Math.double(n : Int) : Int do n * 2 end
  deftest Math.doubles_correctly do
    always(Math.double(2) == 4)
    always(Math.double(0) == 0)
  end
  deftest Math.wrong_expectation do
    always(Math.double(3) == 7)
  end
  """

  defp failures(src, test) do
    case Exec.test(universe(src), test) do
      :ok -> []
      {:error, %{code: "test", failures: failures}} -> failures
    end
  end

  describe "always, sometimes and tests" do
    test "in ordinary code they are recorded and evaluation goes on; their value is Unit" do
      src = """
      def A.check(n : Int) : Int do
        always(n >= 0)
        sometimes(n > 10)
        n
      end
      """

      assert call(src, "A.check", [-1]) == {:ok, -1}
      assert value("always(1 == 2)") == {}
      assert value("sometimes(1 == 2)") == {}
    end

    test "tests pass, or fail with each always that failed (TS deftest declarations)" do
      assert Exec.test(universe(@math), "Math.doubles_correctly") == :ok

      assert {:error, %{code: "test", message: "always failed: Math.double(3) == 7", failures: f}} =
               Exec.test(universe(@math), "Math.wrong_expectation")

      assert f == ["always failed: Math.double(3) == 7"]
    end

    test "one always site, evaluated once per call, reported each time it fails" do
      src = """
      defmodel A.Model do n : Int end
      def A.check(model : A.Model) : Int do
        always(model.n >= 0)
        model.n
      end
      deftest A.checks do
        A.check(%A.Model{n: 5})
        A.check(%A.Model{n: -1})
        A.check(%A.Model{n: -2})
      end
      """

      assert failures(src, "A.checks") == [
               "always failed: model.n >= 0",
               "always failed: model.n >= 0"
             ]
    end

    test "the same expression under always and sometimes is two sites" do
      src = """
      deftest G.both do
        always(1 > 2)
        sometimes(1 > 2)
      end
      """

      assert failures(src, "G.both") == ["always failed: 1 > 2", "never reached: 1 > 2"]
    end

    test "the same expression in two declarations is two sites; a test is held to its own" do
      src = """
      def A.tick(n : Int) : Int do
        sometimes(n > 0)
        n
      end
      deftest A.ticks do
        n = 0
        sometimes(n > 0)
        A.tick(5)
      end
      """

      assert failures(src, "A.ticks") == ["never reached: n > 0"]
    end

    test "a test is not held to another declaration's sometimes" do
      src = """
      def A.tick(n : Int) : Int do
        sometimes(n > 100)
        n
      end
      deftest A.ticks do
        always(A.tick(5) == 5)
      end
      """

      assert failures(src, "A.ticks") == []
    end

    test "a sometimes that holds once is reached, inside a closure too" do
      src = """
      def A.each(xs : List<Int>) : List<Int> do List.map(xs, fn (x : Int) -> x end) end
      deftest A.some do
        ys = List.map([1, 2, 3], fn (x : Int) -> do
          sometimes(x == 2)
          x
        end end)
        always(A.each(ys) == [1, 2, 3])
      end
      """

      assert failures(src, "A.some") == []
    end

    test "never-reached sites come in the order written, each once" do
      src = """
      deftest A.order do
        sometimes(2 > 3)
        sometimes(1 > 2)
        sometimes(2 > 3)
      end
      """

      assert failures(src, "A.order") == ["never reached: 2 > 3", "never reached: 1 > 2"]
    end

    test "a test that fails to evaluate crashes after its failures so far" do
      src = """
      def A.d(x : Int, y : Int) : Int do x / y end
      deftest A.divides do
        always(A.d(4, 2) == 3)
        sometimes(A.d(4, 2) == 2)
        always(A.d(1, 0) == 0)
      end
      """

      assert failures(src, "A.divides") == [
               "always failed: A.d(4, 2) == 3",
               "crashed: division by zero"
             ]
    end

    test "a test failing 100k times lists the first 1000 failures and counts the rest" do
      src = """
      def A.spin(n : Int) : Int do
        if n == 0 do
          0
        else
          always(n < 0)
          A.spin(n - 1)
        end
      end
      deftest A.many do
        always(A.spin(100000) == 0)
      end
      """

      assert {:error, %{code: "test", failures: failures, message: message}} =
               Exec.test(universe(src), "A.many")

      assert length(failures) == 1_001
      assert Enum.take(failures, 2) == ["always failed: n < 0", "always failed: n < 0"]
      assert List.last(failures) == "…and 99000 more"
      assert message =~ ~r/\n…and 99000 more$/
    end

    test "running what is not a test is an error" do
      assert Exec.test(universe(@math), "Math.double") ==
               {:error, %{code: "runtime", message: "no test named `Math.double`"}}
    end

    test "eval and call ignore always and sometimes" do
      assert value("do\n  always(1 == 2)\n  3\nend") == 3
    end
  end

  describe "eval refusals" do
    test "an ill-typed expression or an unknown name is the checker's reason, and spawns nothing" do
      u = universe(@boxes)

      {r1, spawned1} = spawned_during(fn -> Exec.eval(u, "A.double(\"x\")") end)
      assert {:error, %{code: "mismatch", message: _}} = r1
      {r2, spawned2} = spawned_during(fn -> Exec.eval(u, "A.nope(1)") end)
      assert {:error, %{code: "unbound", message: _}} = r2
      {r3, spawned3} = spawned_during(fn -> Exec.eval(u, "1 +") end)
      assert {:error, %{code: "parse", message: _}} = r3

      assert spawned1 ++ spawned2 ++ spawned3 == []
    end
  end

  describe "the worker" do
    @loops """
    def A.loop(n : Int) : Int do A.loop(n + 1) end
    def A.ping(n : Int) : Int do A.pong(n) end
    def A.pong(n : Int) : Int do A.ping(n) end
    def A.grow(n : Int, acc : List<Int>) : List<Int> do
      if n == 0 do acc else A.grow(n - 1, List.append(acc, n)) end
    end
    def A.deep(n : Int) : Int do if n < 0 do 0 else 1 + A.deep(n + 1) end end
    def A.fib(n : Int) : Int do if n < 2 do n else A.fib(n - 1) + A.fib(n - 2) end end
    def A.down(n : Int) : Int do if n == 0 do 0 else 1 + A.down(n - 1) end end
    def A.twice(s : String, n : Int) : String do
      if n == 0 do s else A.twice(s ++ s, n - 1) end
    end
    """

    test "infinite recursion times out, and the worker is gone afterwards" do
      u = universe(@loops)
      # Compiled first: compiling spawns a worker of its own.
      {:ok, _} = Exec.load(u)

      for name <- ["A.loop", "A.ping"] do
        {result, spawned} = spawned_during(fn -> Exec.call(u, name, [0], timeout: 50) end)
        assert {:error, %{code: "timeout", message: _}} = result
        # The worker and its guardian, both gone.
        assert length(spawned) == 2
        Enum.each(spawned, &assert_gone/1)
      end

      assert {:error, %{code: "timeout"}} = Exec.eval(u, "A.fib(40)", timeout: 50)
      assert Exec.call(u, "A.fib", [15]) == {:ok, 610}
    end

    test "a runaway allocation is killed at the heap limit, and the worker is gone" do
      u = universe(@loops)
      {:ok, _} = Exec.load(u)

      {result, spawned} =
        spawned_during(fn ->
          Exec.call(u, "A.grow", [10_000_000, []], max_heap_size: 200_000, timeout: 5_000)
        end)

      assert {:error, %{code: "heap", message: message}} = result
      assert message == "evaluation exceeded the memory limit (1.5 MB, 200000 words)"
      assert length(spawned) == 2
      Enum.each(spawned, &assert_gone/1)

      assert {:error, %{code: "heap"}} =
               Exec.call(u, "A.deep", [0], max_heap_size: 200_000, timeout: 5_000)

      # A string's bytes live off the process heap: they count too.
      assert {:error, %{code: "heap"}} =
               Exec.call(u, "A.twice", ["x", 60], max_heap_size: 200_000, timeout: 5_000)
    end

    test "a worker dies with its caller, long before its own deadline" do
      u = universe(@loops)
      {:ok, image} = Exec.load(u)
      test = self()

      caller =
        spawn(fn ->
          receive do
            :go -> send(test, {:result, Exec.call(u, "A.loop", [0], timeout: 60_000)})
          end
        end)

      {_, spawned} =
        spawned_by(caller, fn ->
          send(caller, :go)
          wait_until_running(image.module)
          Process.exit(caller, :kill)
          assert_gone(caller)
        end)

      # The worker and its guardian.
      assert length(spawned) == 2
      Enum.each(spawned, &assert_gone/1)
      refute_received {:result, _}
    end

    test "a worker stopped by unload answers unloaded" do
      u = universe("def Unl.loop(n : Int) : Int do Unl.loop(n + 1) end")
      {:ok, image} = Exec.load(u)
      task = Task.async(fn -> Exec.call(image, "Unl.loop", [0], timeout: 10_000) end)
      wait_until_running(image.module)
      assert Exec.unload(image) == :ok
      assert {:error, %{code: "unloaded"}} = Task.await(task)
    end

    test "deep recursion within the limits runs" do
      assert Exec.call(universe(@loops), "A.down", [24_999]) == {:ok, 24_999}
      assert Exec.call(universe(@loops), "A.down", [250_000]) == {:ok, 250_000}
      assert Exec.call(universe(@loops), "A.twice", ["ab", 3]) == {:ok, String.duplicate("ab", 8)}
    end

    test "a result too large to hand back is an error, not a copy" do
      binds = Enum.map_join(1..40, "\n", fn i -> "  x#{i} = [x#{i - 1}, x#{i - 1}]" end)
      doubled = &"do\n  x0 = [1]\n#{binds}\n  #{&1}\nend"

      assert error_in("", doubled.("x40")) == "result too large"
      # A huge map is charged its size before its entries are walked.
      assert {:error, %{code: "runtime", message: "result too large"}} =
               Kinoko.Exec.Worker.run(fn -> Map.new(1..1_000_001, &{&1, &1}) end)

      element = String.duplicate("List<", 40) <> "Int" <> String.duplicate(">", 40)
      assert value(doubled.("List.map(x40, fn (x : #{element}) -> 1 end)")) == [1, 1]

      src = """
      deftype A.T do Leaf | Node(A.T, A.T) end
      def A.grow(t : A.T, n : Int) : A.T do
        if n == 0 do t else A.grow(A.T.Node(t, t), n - 1) end
      end
      """

      leaf = var("A.T", "Leaf")
      assert call(src, "A.grow", [leaf, 60]) == {:error, "result too large"}
      assert call(src, "A.grow", [leaf, 1]) == {:ok, var("A.T", "Node", [leaf, leaf])}
    end

    # kinoko-next interp_eval.rs: `=:=` and map hashing never yield, so a
    # value too large to walk is refused before it is compared or hashed.
    test "comparing a value too large to walk runs out of steps" do
      binds = Enum.map_join(1..40, "\n", fn i -> "  x#{i} = [x#{i - 1}, x#{i - 1}]" end)
      doubled = &"do\n  x0 = [1]\n#{binds}\n  #{&1}\nend"
      out_of_steps = "evaluation took more than 1000000 steps"

      assert error_in("", doubled.("x40 == x40")) == out_of_steps
      assert error_in("", doubled.("x40 != x40")) == out_of_steps
      assert error_in("", doubled.("List.member([x40], x40)")) == out_of_steps

      # Two values built apart, each 2^30 elements to walk.
      ys = Enum.map_join(1..30, "\n", fn i -> "  y#{i} = [y#{i - 1}, y#{i - 1}]" end)
      apart = "do\n  x0 = [1]\n  y0 = [1]\n#{binds}\n#{ys}\n  x30 == y30\nend"
      assert error_in("", apart) == out_of_steps

      assert value(doubled.("x10 == x10")) == true
    end

    # Wall clock: what the refusal saves. Only the evaluation is timed (the
    # universe is staged and its image loaded first); the bound is generous,
    # an unrefused walk of 2^40 nodes takes hours.
    @tag :perf
    test "refusing a comparison too large to walk is quick" do
      binds = Enum.map_join(1..40, "\n", fn i -> "  x#{i} = [x#{i - 1}, x#{i - 1}]" end)
      ys = Enum.map_join(1..30, "\n", fn i -> "  y#{i} = [y#{i - 1}, y#{i - 1}]" end)
      u = Lang.snapshot(Lang.new())
      {:ok, _} = Exec.load(u)

      for expr <- [
            "do\n  x0 = [1]\n#{binds}\n  x40 == x40\nend",
            "do\n  x0 = [1]\n  y0 = [1]\n#{binds}\n#{ys}\n  x30 == y30\nend"
          ] do
        {us, result} = :timer.tc(fn -> Exec.eval(u, expr, timeout: 60_000) end)
        assert {:error, %{code: "runtime"}} = result
        assert us < 10_000_000, "#{us} µs"
      end
    end

    # Rust's `Function` equality: `=:=` would compare two closures'
    # captured environments, as large as they come, without yielding.
    test "a closure equals nothing; a def or constructor equals only itself" do
      element = String.duplicate("List<", 29) <> "Int" <> String.duplicate(">", 29)

      src = """
      def A.mk(x : #{element}) : (Int -> Int) do fn (k : Int) -> k + List.length(x) end end
      def A.f(n : Int) : Int do n end
      def A.same(g : (Int -> Int)) : Bool do g == g end
      deftype A.Box do Full(Int) | Empty end
      """

      bind = fn v ->
        Enum.map_join(1..28, "\n", fn i -> "  #{v}#{i} = [#{v}#{i - 1}, #{v}#{i - 1}]" end)
      end

      apart = &"do\n  x0 = [1]\n  y0 = [1]\n#{bind.("x")}\n#{bind.("y")}\n  #{&1}\nend"

      u = universe(src)
      {:ok, _} = Exec.load(u)

      # Comparing the environments (2^28 elements each, equal) would not
      # end within the deadline: the answer coming back at all shows they
      # were not compared.
      for expr <- ["A.mk(x28) == A.mk(y28)", "List.member([A.mk(x28)], A.mk(y28))"] do
        assert {:ok, false, _} = Exec.eval(u, apart.(expr), timeout: 2_000), expr
      end

      assert value_in(src, "A.mk(x28) != A.mk(y28)" |> apart.()) == true
      assert value_in(src, "A.same(fn (n : Int) -> n end)") == false
      assert value_in(src, "A.same(A.f)") == true
      assert value_in(src, "A.f == A.f") == true
      assert value_in(src, "[A.f] == [A.f]") == true
      assert value_in(src, "String.length == String.length") == true
      assert value_in(src, "A.Box.Full == A.Box.Full") == true
      assert value_in(src, "(1, A.Box.Full) == (1, A.Box.Full)") == true
      assert value_in(src, "List.member([A.f], A.f)") == true
      assert value_in(src, "List.member([fn (n : Int) -> n end], A.f)") == false
    end

    test "a map key too large to compare runs out of steps" do
      binds = Enum.map_join(1..40, "\n", fn i -> "  x#{i} = [x#{i - 1}, x#{i - 1}]" end)
      doubled = &"do\n  x0 = [1]\n#{binds}\n  #{&1}\nend"

      assert error_in("", doubled.("%{x40 => 1, x40 => 2}")) ==
               "evaluation took more than 1000000 steps"

      assert value(doubled.("%{x2 => 1, x2 => 2}")) == value("%{[[[1], [1]], [[1], [1]]] => 2}")
    end

    test "a deadline kill is a timeout, never the heap limit" do
      # The reason the guardian kills a worker with at its deadline.
      assert {:error, %{code: "timeout"}} =
               Kinoko.Exec.Worker.run(fn -> Process.exit(self(), :kinoko_deadline) end)
    end

    test "a fault that is no Yabu error is internal" do
      u = universe(@boxes)
      # A string where an Int belongs: the checker never lets this through.
      assert {:error, %{code: "internal", message: m}} = Exec.call(u, "A.double", ["x"])
      assert m =~ "badarith" or m =~ "ArithmeticError" or m =~ "expected"
    end
  end

  describe "images" do
    test "identical universes share a module, loaded once" do
      src = "def Share.one() : Int do 1 end"
      {:ok, a} = Exec.load(universe(src))
      refute :erlang.check_old_code(a.module)
      {:ok, b} = Exec.load(universe(src))
      assert a.module == b.module
      assert a.hash == b.hash
      # A second load_binary would have made the first the module's old code.
      refute :erlang.check_old_code(a.module)
      assert {:file, _} = :code.is_loaded(a.module)
    end

    test "a universe is not accepted, only a snapshot or image" do
      u = Lang.new()
      assert_raise FunctionClauseError, fn -> Exec.load(u) end
      assert_raise FunctionClauseError, fn -> Exec.eval(u, "1") end
      assert_raise FunctionClauseError, fn -> Exec.call(u, "A.f", []) end
    end

    test "after a promotion the old image still answers its old body" do
      {u1, {:promoted, _}} = Lang.stage(Lang.new(), "p", "def Ver.n() : Int do 1 end")
      {:ok, old} = Exec.load(Lang.snapshot(u1))
      {u2, {:promoted, _}} = Lang.stage(u1, "p", "def Ver.n() : Int do 2 end")
      {:ok, new} = Exec.load(Lang.snapshot(u2))

      refute old.module == new.module
      assert Exec.call(old, "Ver.n", []) == {:ok, 1}
      assert Exec.call(new, "Ver.n", []) == {:ok, 2}
      assert Exec.call(Lang.snapshot(u1), "Ver.n", []) == {:ok, 1}
    end

    test "unload purges the module and forgets it; a later load brings it back" do
      u = universe("def Gone.n() : Int do 7 end")
      {:ok, image} = Exec.load(u)
      assert Exec.unload(image) == :ok
      refute :code.is_loaded(image.module)
      assert Exec.unload(image) == :ok
      assert Exec.call(u, "Gone.n", []) == {:ok, 7}
      assert {:file, _} = :code.is_loaded(image.module)
    end

    test "a module purged behind the cache's back is loaded again" do
      u = universe("def Behind.n() : Int do 8 end")
      {:ok, image} = Exec.load(u)
      :code.purge(image.module)
      :code.delete(image.module)
      :code.purge(image.module)
      assert Exec.call(u, "Behind.n", []) == {:ok, 8}
    end

    test "compiling is bounded by compile_timeout, and the caller survives" do
      stmts = Enum.map_join(0..3_000, "\n", &"  x#{&1} = #{&1} + 1")
      u = universe("def Slow.f() : Int do\n#{stmts}\n  0\nend")

      assert {:error, %{code: "timeout", message: "compiling the image took more than 1 ms"}} =
               Exec.load(u, compile_timeout: 1)

      assert {:error, %{code: "timeout"}} = Exec.call(u, "Slow.f", [], compile_timeout: 1)
      assert Exec.call(u, "Slow.f", []) == {:ok, 0}
    end

    test "concurrent loads and unloads never collide" do
      u = universe("def Race.n() : Int do 5 end")
      {:ok, image} = Exec.load(u)

      results =
        1..40
        |> Task.async_stream(
          fn i ->
            if rem(i, 2) == 0,
              do: Exec.unload(image),
              else: Exec.call(u, "Race.n", [])
          end,
          max_concurrency: 40,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, r} -> r end)

      for r <- results do
        assert r in [:ok, {:ok, 5}] or match?({:error, %{code: "unloaded"}}, r), inspect(r)
      end

      assert Exec.call(u, "Race.n", []) == {:ok, 5}
    end

    test "a closure or def value of an unloaded image raises when called, inside a worker" do
      src = """
      def Gone.f(n : Int) : Int do n end
      def Gone.mk(n : Int) : (Int -> Int) do fn (k : Int) -> k + n end end
      """

      u = universe(src)
      {:ok, image} = Exec.load(u)
      {:ok, closure} = Exec.call(image, "Gone.mk", [1])
      {:ok, def_value, _} = Exec.eval(u, "Gone.f")
      assert Kinoko.Exec.Worker.run(fn -> closure.(1) end) == {:ok, 2}

      assert Exec.unload(image) == :ok

      for f <- [closure, def_value] do
        assert {:error, %{code: "internal", message: m}} =
                 Kinoko.Exec.Worker.run(fn -> f.(1) end)

        assert m =~ "badfun" or m =~ "undef" or m =~ "UndefinedFunctionError", m
      end
    end

    test "the image lists each test's sometimes sites" do
      src = """
      deftest S.t do
        sometimes(1 > 2)
        always(sometimes(2 > 3) == sometimes(2 > 3))
      end
      """

      {:ok, image} = Exec.load(universe(src))
      assert image.sometimes == %{"S.t" => ["1 > 2", "2 > 3"]}
    end

    test "the counter steps" do
      u = universe(File.read!("test/fixtures/yabu/counter.yabu"))
      {:ok, {model, {:cmd, :none}}} = Exec.call(u, "Counter.init", [])
      {:ok, {model, _}} = Exec.call(u, "Counter.update", [var("Counter.Msg", "Increment"), model])
      assert model == rec("Counter.Model", [{"count", 1}])

      assert {:ok, {^model, _}, {:tuple, _}} =
               Exec.eval(u, "Counter.update(Counter.Msg.Add(-5), %Counter.Model{count: 1})")
    end
  end
end
