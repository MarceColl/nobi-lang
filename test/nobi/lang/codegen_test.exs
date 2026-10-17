defmodule Nobi.Lang.CodegenTest do
  # Loads modules into the VM: not async, so two tests never load or purge
  # the same image at once.
  use ExUnit.Case, async: false

  alias Nobi.Exec.Hooks
  alias Nobi.Lang
  alias Nobi.Lang.Codegen

  @counter File.read!("test/fixtures/nobi/counter.nobi")
  @split File.read!("test/fixtures/nobi/split.nobi")

  # Every store form: their values hold fixed atoms only (`:tx`, the op).
  @store ~S"""
  deftype S.Msg do Saved(Uuid) | Rows(List<S.Row>) | Done(Result<(List<Uuid>, Int), String>) end
  defmodel S.Row do
    id : Uuid
    n : Int = 0
  end
  def S.save(r : S.Row) : Cmd<S.Msg> do Cmd.store.insert(r, S.Msg.Saved) end
  def S.rows() : Cmd<S.Msg> do Cmd.store.list(S.Msg.Rows) end
  def S.bump(id : Uuid) : Cmd<S.Msg> do
    Cmd.store.tx(
      fn (s : Store) ->
        case Store.get(s, id) do
          Option.Some(r) -> ([Tx.update(id, %S.Row{r | n: r.n + 1}), Tx.delete(S.Row, id)], 1)
          Option.None -> (List.map((Store.list(s) : List<S.Row>), Tx.insert), 0)
        end
      end,
      S.Msg.Done
    )
  end
  """

  defp universe(source) do
    {u, r} = Lang.stage(Lang.new(), "p", source)
    assert {:promoted, _} = r
    u
  end

  # Loads an image (tests only: `Nobi.Lang` never loads code).
  defp load(%{module: mod, binary: bin}) do
    {:module, ^mod} = :code.load_binary(mod, ~c"nobi", bin)

    on_exit(fn ->
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end)

    mod
  end

  defp image!(source) do
    {:ok, image} = source |> universe() |> Lang.image()
    image
  end

  defp call(image, name, args) do
    {fun, arity} = Map.fetch!(image.names, name)
    ^arity = length(args)
    apply(image.module, fun, args)
  end

  defp sources do
    corpus = Enum.map(NobiGolden.corpus(), &{&1["file"], NobiOracle.corpus_source(&1["file"])})

    generated =
      NobiGolden.generated()
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> {"generated[#{i}]", p["source"]} end)

    corpus ++ generated ++ [{"store", @store}]
  end

  describe "compiling" do
    test "every corpus and generated program compiles without errors or warnings" do
      for {label, source} <- sources() do
        committed = source |> universe() |> Lang.committed()
        {_mod, forms, _names, _tests} = Codegen.forms(committed)

        case :compile.noenv_forms(forms, Codegen.compile_options()) do
          {:ok, _mod, bin, warnings} when is_binary(bin) ->
            assert warnings == [], "#{label}: #{inspect(warnings)}"

          other ->
            flunk("#{label}: #{inspect(other, limit: 20)}")
        end
      end
    end

    test "an image is deterministic, and named by its code alone" do
      a = image!(@counter)
      b = image!(@counter)
      assert a.module == b.module
      assert a.binary == b.binary
      assert a.hash == Codegen.image_hash(Lang.committed(universe(@counter)))
      assert Atom.to_string(a.module) == "nobi_img_" <> binary_part(a.hash, 0, 20)
      assert a.hash =~ ~r/^[0-9a-f]{64}$/

      c = image!(@counter <> "\ndef Counter.extra() : Int do\n  1\nend\n")
      refute c.module == a.module
    end

    test "the image hash is sha256 of the sorted name\\0cid lines" do
      committed = Lang.committed(universe(@counter))

      lines =
        committed
        |> Enum.sort()
        |> Enum.map_join(fn {name, %{cid: cid}} -> name <> "\0" <> cid <> "\n" end)

      assert Codegen.image_hash(committed) ==
               Base.encode16(:crypto.hash(:sha256, lines), case: :lower)
    end

    @allowed ~w(attribute module export function clause call remote var atom integer
                string bin bin_element default utf8 integer tuple cons nil map
                map_field_assoc match case fun clauses block op andalso orelse not
                eof true false rec uuid cmd none batch effect names image models types routes tests segments app params lit param
                _ - =:= =/= < > =< >= named applied arrow maps from_list
                tx insert update delete)a

    test "no atom in the forms comes from user text" do
      for {label, source} <- sources() do
        committed = source |> universe() |> Lang.committed()
        {mod, forms, _names, _tests} = Codegen.forms(committed)

        modules = [
          Nobi.Lang.Rt,
          Nobi.Lang.Rt.Stdlib,
          Nobi.Lang.Rt.Json,
          Nobi.Exec.Hooks,
          Nobi.Data.Hooks
        ]

        stdlib_funs =
          for name <- Nobi.Lang.Types.Stdlib.names(),
              {_, f, _} <- [Nobi.Lang.Rt.Stdlib.function_for(name)],
              do: f

        rt_funs = Enum.flat_map(modules, fn m -> Keyword.keys(m.__info__(:functions)) end)
        allowed = MapSet.new(@allowed ++ modules ++ stdlib_funs ++ rt_funs ++ [:__nobi__, mod])

        for atom <- atoms(forms), not MapSet.member?(allowed, atom) do
          assert Atom.to_string(atom) =~ ~r/^(d\d+|V\d+)$/, "#{label}: #{inspect(atom)}"
        end
      end
    end

    test "a user name that looks like an atom stays a binary" do
      src = """
      deftype Erlang.Spawn do
        Exit | Halt(Int)
      end

      def Erlang.halt(x : Int) : Erlang.Spawn do
        case x do
          0 -> Erlang.Spawn.Exit
          n -> Erlang.Spawn.Halt(n)
        end
      end
      """

      {_mod, forms, _names, _tests} = Codegen.forms(Lang.committed(universe(src)))
      refute :halt in atoms(forms)
      refute :Exit in atoms(forms)
    end
  end

  defp atoms(term) when is_atom(term), do: [term]
  defp atoms(term) when is_list(term), do: Enum.flat_map(term, &atoms/1)
  defp atoms(term) when is_tuple(term), do: term |> Tuple.to_list() |> atoms()

  defp atoms(term) when is_map(term),
    do: Enum.flat_map(term, fn {k, v} -> atoms(k) ++ atoms(v) end)

  defp atoms(_), do: []

  describe "caps on generated atoms" do
    # A def binding `n` locals, each one Erlang variable.
    defp bindings(n) do
      stmts = Enum.map_join(0..(n - 1), "\n", &"  x#{&1} = #{&1}")
      "def Big.f() : Int do\n#{stmts}\n  0\nend\n"
    end

    test "a def may use up to max_vars variables, and is refused past it" do
      max = Codegen.Expr.max_vars()
      assert max == 10_000
      assert {:ok, image} = bindings(max) |> universe() |> Lang.image()
      assert load(image) |> apply(:d0, []) == 0

      assert {:error, %{code: "compile", message: message}} =
               bindings(max + 1) |> universe() |> Lang.image()

      assert message =~ "`Big.f` needs more than 10000 Erlang variables"
      # The refusal came before the atom past the cap was made.
      assert_raise ArgumentError, fn -> String.to_existing_atom("V#{max}") end
    end

    test "an image of more than max_functions defs and tests is refused before naming them" do
      max = Codegen.max_functions()
      assert max == 20_000

      committed =
        for i <- 0..max, into: %{} do
          name = "Many.f#{i}"
          {name, %{cid: "c#{i}", typed: {:def, [], [name, [], :int, {:int, [], [0]}]}}}
        end

      assert {:error, %{code: "compile", message: message}} = Codegen.compile(committed)
      assert message =~ "20001 defs and tests; at most 20000"
      assert_raise ArgumentError, fn -> String.to_existing_atom("d#{max}") end
    end
  end

  describe "the image module" do
    test "__nobi__ answers names, image, models, types and tests" do
      image = image!(@split)
      mod = load(image)
      committed = Lang.committed(universe(@split))

      defs = for {n, %{signature: {:def, _, _, _}}} <- committed, do: n
      assert Enum.sort(Map.keys(mod.__nobi__(:names))) == Enum.sort(defs)
      assert mod.__nobi__(:names) == image.names
      assert mod.__nobi__(:image) == image.hash

      assert Map.keys(mod.__nobi__(:tests)) |> Enum.sort() ==
               [
                 "Split.handles_an_empty_trip",
                 "Split.money_prints_cents",
                 "Split.splits_what_was_paid"
               ]

      assert mod.__nobi__(:models)["Split.Share"] == [
               {"who", {:named, "String"}, :none},
               {"owes", {:named, "Int"}, :none}
             ]

      assert {[], [{"SetPayer", _} | _]} = mod.__nobi__(:types)["Split.Msg"]

      for {_name, {fun, arity}} <- image.names do
        assert function_exported?(mod, fun, arity)
      end
    end

    test "the counter steps" do
      image = image!(@counter)
      load(image)
      model = fn n -> {:rec, "Counter.Model", %{"count" => n}} end
      msg = fn v, args -> {:var, "Counter.Msg", v, args} end

      assert call(image, "Counter.init", []) == {model.(0), {:cmd, :none}}

      assert call(image, "Counter.update", [msg.("Increment", []), model.(1)]) ==
               {model.(2), {:cmd, :none}}

      assert call(image, "Counter.update", [msg.("Add", [10]), model.(1)]) ==
               {model.(11), {:cmd, :none}}

      assert call(image, "Counter.update", [msg.("Add", [-10]), model.(1)]) ==
               {model.(1), {:cmd, :none}}

      assert {:var, "Html", "Element", ["div", [{"class", "counter"}], children]} =
               call(image, "Counter.view", [model.(7)])

      assert Enum.at(children, 0) ==
               {:var, "Html", "Element",
                ["button", [{"on-click", msg.("Decrement", [])}], [{:var, "Html", "Text", ["-"]}]]}

      assert Enum.at(children, 1) ==
               {:var, "Html", "Element", ["span", [], [{:var, "Html", "Text", ["7"]}]]}
    end

    test "a false always is recorded and evaluation goes on" do
      image = image!(@counter)
      load(image)
      Hooks.take_failures()
      bad = {:rec, "Counter.Model", %{"count" => -1}}

      assert {{:rec, "Counter.Model", %{"count" => 0}}, {:cmd, :none}} =
               call(image, "Counter.update", [{:var, "Counter.Msg", "Increment", []}, bad])

      assert Hooks.take_failures() == ["always failed: model.count >= 0"]
      assert Hooks.take_failures() == []
    end

    test "deftests run, each failing always recorded in order" do
      src = """
      def T.one() : Int do
        1
      end

      deftest T.t do
        always(T.one() == 2)
        sometimes(T.one() == 1)
        always(T.one() == 1)
        always(T.one() == 3)
      end
      """

      image = image!(src)
      mod = load(image)
      Hooks.take_failures()
      fun = Map.fetch!(image.tests, "T.t")
      assert apply(mod, fun, []) == {}

      assert Hooks.take_failures() == [
               "always failed: T.one() == 2",
               "always failed: T.one() == 3"
             ]

      # A `sometimes` that held is recorded under its declaration.
      assert Hooks.take_reached() == MapSet.new([{"T.t", "T.one() == 1"}])
      assert image.sometimes == %{"T.t" => ["T.one() == 1"]}

      # Outside a declaration, `sometimes` only evaluates its argument.
      {:ok, typed, _} = Lang.check_expr(universe(src), "sometimes(T.one() == 1)")
      forms = Codegen.expr_forms(typed, image.names, image.module)
      assert {:value, {}, _} = :erl_eval.exprs(forms, :erl_eval.new_bindings())
      assert Hooks.take_reached() == MapSet.new()
    end

    test "runtime errors are Rust's" do
      src = """
      def E.div(a : Int, b : Int) : Int do
        a / b
      end

      def E.big(a : Int) : Int do
        a * a
      end
      """

      image = image!(src)
      load(image)
      assert call(image, "E.div", [7, -2]) == -3
      assert catch_throw(call(image, "E.div", [1, 0])) == {:nobi_error, "division by zero"}

      assert catch_throw(call(image, "E.big", [4_000_000_000])) ==
               {:nobi_error, "integer overflow"}
    end

    test "arguments are evaluated left to right" do
      src = """
      def O.f(a : Int, b : Int) : Int do
        a + b
      end

      def O.go(x : Int) : Int do
        O.f(1 / x, 2 * 9223372036854775807)
      end
      """

      image = image!(src)
      load(image)
      assert catch_throw(call(image, "O.go", [0])) == {:nobi_error, "division by zero"}
    end

    test "closures, defs and constructors as values, blocks, cases on tuples" do
      src = """
      deftype F.Box do
        Box(Int) | Empty
      end

      def F.inc(x : Int) : Int do
        x + 1
      end

      def F.adder(k : Int) : (Int -> Int) do
        fn (x : Int) -> x + k end
      end

      def F.go(xs : List<Int>) : (List<Int>, List<F.Box>, Int) do
        k = 100
        ys = List.map(List.map(xs, F.adder(10)), F.inc)
        boxes = List.map(xs, F.Box.Box)
        n = case (List.length(xs), List.head(xs)) do
          (0, _) -> 0
          (_, Option.Some(h)) -> h + k
          (_, Option.None) -> -1
        end
        (ys, boxes, n)
      end

      def F.words(s : String) : Int do
        case s do
          "héllo" -> 1
          _ -> 2
        end
      end
      """

      image = image!(src)
      load(image)

      assert call(image, "F.go", [[1, 2]]) ==
               {[12, 13], [{:var, "F.Box", "Box", [1]}, {:var, "F.Box", "Box", [2]}], 101}

      assert call(image, "F.go", [[]]) == {[], [], 0}
      assert call(image, "F.words", ["héllo"]) == 1
      assert call(image, "F.words", ["hello"]) == 2
    end

    test "maps, records, updates, JSON with the model's field order, store reads" do
      src = """
      defmodel J.Row do
        id : Uuid
        zeta : Int
        alpha : String
      end

      deftype J.Msg do
        Got(List<J.Row>) | Text(Result<String, String>)
      end

      def J.go(n : Int) : (Map<String, Int>, J.Row, Result<String, String>, Result<J.Row, String>) do
        m = %{"a" => 1, "b" => n, "a" => 3}
        r = %J.Row{zeta: n, alpha: "x"}
        r2 = %J.Row{r | alpha: "y"}
        (m, r2, JSON.stringify(r2), (JSON.parse("{\\"id\\": \\"00000000-0000-0000-0000-000000000001\\", \\"zeta\\": 2, \\"alpha\\": \\"q\\"}") : Result<J.Row, String>))
      end

      def J.load() : Cmd<J.Msg> do
        Cmd.store.list(fn (rows : List<J.Row>) -> J.Msg.Got(rows) end)
      end

      def J.as_value() : List<Result<String, String>> do
        List.map([1, 2], JSON.stringify)
      end
      """

      image = image!(src)
      load(image)

      row = {:rec, "J.Row", %{"zeta" => 5, "alpha" => "y"}}

      assert {%{"a" => 3, "b" => 5}, ^row, ok, parsed} = call(image, "J.go", [5])
      assert ok == {:var, "Result", "Ok", [~s({"zeta":5,"alpha":"y"})]}

      assert parsed ==
               {:var, "Result", "Ok",
                [
                  {:rec, "J.Row",
                   %{
                     "id" => {:uuid, "00000000-0000-0000-0000-000000000001"},
                     "zeta" => 2,
                     "alpha" => "q"
                   }}
                ]}

      assert {:cmd, {:effect, "Cmd.store.list", "J.Row", [cb]}} = call(image, "J.load", [])
      assert cb.([]) == {:var, "J.Msg", "Got", [[]]}

      assert call(image, "J.as_value", []) == [
               {:var, "Result", "Ok", ["1"]},
               {:var, "Result", "Ok", ["2"]}
             ]
    end
  end

  describe "expressions against an image" do
    test "check_expr types an expression against committed code" do
      u = universe(@counter)

      assert {:ok, typed, {:tuple, [{:named, "Counter.Model"}, _]}} =
               Lang.check_expr(u, "Counter.init()")

      assert {:call, _, ["Counter.init", []]} = typed

      assert {:error, [%{code: "unbound"}]} = Lang.check_expr(u, "Counter.nope()")
      assert {:error, [%{code: "parse"}]} = Lang.check_expr(u, "(")
    end

    test "expr_forms evaluate with :erl_eval, calling the image remotely" do
      u = universe(@counter)
      {:ok, image} = Lang.image(u)
      load(image)

      {:ok, typed, _} =
        Lang.check_expr(u, "Counter.update(Counter.Msg.Add(5), %Counter.Model{count: 1})")

      forms = Codegen.expr_forms(typed, image.names, image.module)
      {:value, v, _} = :erl_eval.exprs(forms, :erl_eval.new_bindings())
      assert v == {{:rec, "Counter.Model", %{"count" => 6}}, {:cmd, :none}}

      {:ok, typed, _} =
        Lang.check_expr(u, "List.map([1, 2], fn (x : Int) -> x * 2 end)")

      forms = Codegen.expr_forms(typed, image.names, image.module)
      assert {:value, [2, 4], _} = :erl_eval.exprs(forms, :erl_eval.new_bindings())

      {:ok, typed, _} = Lang.check_expr(u, "Counter.view")
      forms = Codegen.expr_forms(typed, image.names, image.module)
      {:value, f, _} = :erl_eval.exprs(forms, :erl_eval.new_bindings())
      {fun, 1} = image.names["Counter.view"]
      assert f == Function.capture(image.module, fun, 1)
    end
  end
end
