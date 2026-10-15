defmodule Kinoko.Exec.StdlibTest do
  # Loads images: not async.
  use ExUnit.Case, async: false

  alias Kinoko.Exec
  alias Kinoko.Lang
  alias Kinoko.Lang.Rt
  alias Kinoko.Lang.Types.Stdlib, as: Sigs

  # The program-level tests of kinoko-next `tests/interp_stdlib.rs` that
  # Task 2 left for the evaluator (task-2-report.md, "Deferred to Task 4").

  @id "0b9e2c4a-1f3d-4e5f-8a7b-6c5d4e3f2a1b"

  # TS integers stop at 2^53; Rust's Int is i64, where this parses.
  @divergent ["String.to_int(\"9007199254740993\") == Option.None"]

  defp universe(""), do: Lang.snapshot(Lang.new())

  defp universe(src) do
    {u, r} = Lang.stage(Lang.new(), "p", src)
    assert {:promoted, _} = r, inspect(r)
    Lang.snapshot(u)
  end

  defp value_in(src, expr) do
    case Exec.eval(universe(src), expr) do
      {:ok, v, _} -> v
      other -> flunk("#{expr}: #{inspect(other)}")
    end
  end

  defp value(expr), do: value_in("", expr)

  defp call(u, name, args) do
    case Exec.call(u, name, args) do
      {:ok, v} -> {:ok, v}
      {:error, %{code: "runtime", message: m}} -> {:error, m}
    end
  end

  defp var(owner, variant, args \\ []), do: {:var, owner, variant, args}
  defp rec(model, fields), do: {:rec, model, Map.new(fields)}
  defp ok(v), do: var("Result", "Ok", [v])
  defp err(why), do: var("Result", "Err", [why])
  defp uuid, do: {:uuid, @id}
  defp ctor(owner, variant), do: Rt.ctor(owner, variant, 1)
  defp effect(name, args), do: {:cmd, {:effect, name, nil, args}}
  defp read(name, model, args), do: {:cmd, {:effect, name, model, args}}

  describe "the oracle" do
    test "every stdlib example holds, but the divergent one (TS stdlib.test.ts)" do
      rows = YabuGolden.stdlib()
      u = Lang.snapshot(Lang.new())

      results =
        for %{"name" => name, "examples" => examples} <- rows, example <- examples do
          {name, example, Exec.eval(u, example)}
        end

      failures =
        for {name, example, r} <- results,
            example not in @divergent,
            r != {:ok, true, {:named, "Bool"}},
            do: "#{name}: `#{example}` gave #{inspect(r)}"

      assert failures == []
      assert {length(rows), length(results)} == {36, 94}

      [divergent] = @divergent
      assert value(divergent) == false
    end

    # `Map` is this port's own (kinoko-next has none): no oracle rows, its
    # cases are `Kinoko.Lang.MapStdlibTest`'s.
    test "every row is a stdlib def, and every stdlib def but Cmd/JSON/Tx/Map has examples" do
      rows = Enum.map(YabuGolden.stdlib(), & &1["name"])
      sigs = Sigs.signatures()

      for name <- rows, do: assert(match?({:def, _, _}, sigs[name]), name)

      exempt? = &String.starts_with?(&1, ["Cmd.", "JSON.", "Tx.", "Map."])

      for {name, {:def, _, _}} <- sigs,
          not exempt?.(name),
          do: assert(name in rows, "#{name}: a stdlib def without examples")
    end
  end

  test "a stdlib def applied as a value is the same function" do
    assert value(~S|List.map(["a", "bb", "👋"], String.length)|) == [1, 2, 1]
    assert value("List.filter_map([[1], [], [2, 3]], List.head)") == [1, 2]
    assert value(~S|List.foldl(["a", "b"], "", String.concat)|) == "ba"
  end

  test "appending never changes a list another value holds" do
    got =
      value("""
      do
        xs = [1]
        ys = List.append(List.append(xs, 2), 3)
        zs = List.concat(List.append(ys, 4), ys)
        (xs, ys, zs)
      end
      """)

    assert got == {[1], [1, 2, 3], [1, 2, 3, 4, 1, 2, 3]}
  end

  # As Rust: a closure equals nothing, not even itself.
  test "List.member finds a def, and no closure, as equality does" do
    src = """
    def A.f(n : Int) : Int do n end
    def A.has(f : (Int -> Int)) : Bool do List.member([f], f) end
    """

    assert value_in(src, "A.has(A.f)") == true
    assert value_in(src, "A.has(fn (n : Int) -> n end)") == false
  end

  @effects ~S"""
  deftype C.Msg do Got(Int) | Saved(Uuid) | Rows(List<C.Row>) | Row(Option<C.Row>) | Ids(List<Uuid>) | Text(String) | Maybe(Option<String>) | Keys(List<String>) end
  defmodel C.Row do
    id : Uuid
    text : String
  end
  def C.row() : C.Row do %C.Row{text: "t"} end
  def C.effects(id : Uuid) : List<Cmd<C.Msg>> do
    [
      Cmd.store.insert(C.row(), C.Msg.Saved),
      Cmd.store.list(C.Msg.Rows),
      Cmd.store.get(id, C.Msg.Row),
      Cmd.store.update(id, C.row(), C.Msg.Saved),
      Cmd.store.delete(id, C.Msg.Row),
      Cmd.store.tx([Tx.insert(C.row())], C.Msg.Ids),
      Cmd.time.now(C.Msg.Got),
      Cmd.random.int(1, 6, fn (n : Int) -> C.Msg.Got(n * 2) end),
      Cmd.blob.put("k", "v", C.Msg.Text),
      Cmd.blob.get("k", C.Msg.Maybe),
      Cmd.blob.list("p", C.Msg.Keys),
      Cmd.blob.delete("k", C.Msg.Text),
      Cmd.ai.generate("m", "p", C.Msg.Text)
    ]
  end
  def C.batch() : Cmd<C.Msg> do Cmd.batch([Cmd.none(), Cmd.batch([Cmd.time.now(C.Msg.Got)])]) end
  def C.ops(id : Uuid) : List<Tx.Op> do [Tx.insert(C.row()), Tx.update(id, C.row()), Tx.delete(C.row())] end
  """

  describe "effects as data" do
    test "every effect is its name and its arguments" do
      u = universe(@effects)
      {:ok, cmds} = call(u, "C.effects", [uuid()])
      row = rec("C.Row", [{"text", "t"}])
      msg = &ctor("C.Msg", &1)

      expected = [
        effect("Cmd.store.insert", [row, msg.("Saved")]),
        read("Cmd.store.list", "C.Row", [msg.("Rows")]),
        read("Cmd.store.get", "C.Row", [uuid(), msg.("Row")]),
        effect("Cmd.store.update", [uuid(), row, msg.("Saved")]),
        read("Cmd.store.delete", "C.Row", [uuid(), msg.("Row")]),
        effect("Cmd.store.tx", [[var("Tx", "insert", [row])], msg.("Ids")]),
        effect("Cmd.time.now", [msg.("Got")]),
        :random,
        effect("Cmd.blob.put", ["k", "v", msg.("Text")]),
        effect("Cmd.blob.get", ["k", msg.("Maybe")]),
        effect("Cmd.blob.list", ["p", msg.("Keys")]),
        effect("Cmd.blob.delete", ["k", msg.("Text")]),
        effect("Cmd.ai.generate", ["m", "p", msg.("Text")])
      ]

      effect_rows =
        for {"Cmd." <> _ = n, {:def, _, _}} <- Sigs.signatures(),
            n not in ["Cmd.none", "Cmd.batch"],
            do: n

      assert length(cmds) == length(expected)
      assert length(effect_rows) == length(expected), "one case per effect row"

      for {cmd, want} <- Enum.zip(cmds, expected) do
        case want do
          :random ->
            assert {:cmd, {:effect, "Cmd.random.int", nil, [1, 6, f]}} = cmd
            assert is_function(f, 1)
            assert f.(3) == var("C.Msg", "Got", [6])

          _ ->
            assert cmd == want
        end

        {:cmd, {:effect, name, _, _}} = cmd
        assert name in effect_rows
      end
    end

    test "Cmd.none and Cmd.batch hold what they are given" do
      u = universe(@effects)
      now = {:effect, "Cmd.time.now", nil, [ctor("C.Msg", "Got")]}
      assert call(u, "C.batch", []) == {:ok, {:cmd, {:batch, [:none, {:batch, [now]}]}}}
      assert value_in(@effects, "List.length([Cmd.none(), C.batch()])") == 2
    end

    test "Tx ops are the calls that build them" do
      u = universe(@effects)
      row = rec("C.Row", [{"text", "t"}])

      ops = [
        var("Tx", "insert", [row]),
        var("Tx", "update", [uuid(), row]),
        var("Tx", "delete", [row])
      ]

      assert call(u, "C.ops", [uuid()]) == {:ok, ops}
      assert Exec.show(hd(ops), {:named, "Tx.Op"}) == ~S|Tx.insert(%C.Row{text: "t"})|
    end
  end

  @crud ~S"""
  defmodel Item.Row do
    id : Uuid
    value : String
  end
  defmodel R.Model do
    items : List<Item.Row>
  end
  deftype R.Msg do Loaded(List<Item.Row>) | Got(Option<Item.Row>) | Fetch(Uuid) | Rename(Item.Row) | Remove(Uuid) | Saved(Uuid) | Removed(Option<Item.Row>) end
  def R.init() : (R.Model, Cmd<R.Msg>) do
    (%R.Model{items: []}, Cmd.store.list(fn (rs : List<Item.Row>) -> R.Msg.Loaded(rs) end))
  end
  def R.update(msg : R.Msg, model : R.Model) : (R.Model, Cmd<R.Msg>) do
    case msg do
      R.Msg.Loaded(rs) -> (%R.Model{model | items: rs}, Cmd.none())
      R.Msg.Fetch(id) -> (model, Cmd.store.get(id, fn (o : Option<Item.Row>) -> R.Msg.Got(o) end))
      R.Msg.Got(o) -> (model, Cmd.none())
      R.Msg.Rename(row) -> (model, Cmd.store.update(row.id, %Item.Row{row | value: "renamed"}, fn (id : Uuid) -> R.Msg.Saved(id) end))
      R.Msg.Remove(id) -> (model, Cmd.store.delete(id, fn (o : Option<Item.Row>) -> R.Msg.Removed(o) end))
      R.Msg.Saved(id) -> (model, Cmd.none())
      R.Msg.Removed(o) -> (model, Cmd.none())
    end
  end
  def R.view(model : R.Model) : Html<R.Msg> do <div></div> end
  defapp R
  def R.rows(f : (List<Item.Row> -> R.Msg), rows : List<Item.Row>) : R.Msg do f(rows) end
  def R.row(f : (Option<Item.Row> -> R.Msg), row : Option<Item.Row>) : R.Msg do f(row) end
  def R.id(f : (Uuid -> R.Msg), id : Uuid) : R.Msg do f(id) end
  """

  # The effect `R.update` answers `msg` with, from `init`'s model.
  defp crud_effect(u, msg) do
    {:ok, {model, _}} = call(u, "R.init", [])
    {:ok, {_, {:cmd, {:effect, name, read_model, args}}}} = call(u, "R.update", [msg, model])
    {name, read_model, args}
  end

  describe "store effects (TS codegen.test.ts CRUD)" do
    test "store.list lowers with the model taken from the callback's List<M> element" do
      u = universe(@crud)
      {:ok, {_, {:cmd, {:effect, name, model, [cb]}}}} = call(u, "R.init", [])
      assert {name, model} == {"Cmd.store.list", "Item.Row"}
      rows = [rec("Item.Row", [{"value", "a"}])]
      assert call(u, "R.rows", [cb, rows]) == {:ok, var("R.Msg", "Loaded", [rows])}
    end

    test "store.get lowers with the model from Option<M> and carries the id" do
      u = universe(@crud)
      {name, model, [id, cb]} = crud_effect(u, var("R.Msg", "Fetch", [uuid()]))
      assert {name, model, id} == {"Cmd.store.get", "Item.Row", uuid()}
      some = var("Option", "Some", [rec("Item.Row", [{"value", "x"}])])
      assert call(u, "R.row", [cb, some]) == {:ok, var("R.Msg", "Got", [some])}
    end

    test "store.update lowers with id, value and the model from the value's type" do
      u = universe(@crud)
      row = &rec("Item.Row", [{"id", uuid()}, {"value", &1}])
      {name, model, [id, value, cb]} = crud_effect(u, var("R.Msg", "Rename", [row.("old")]))
      assert {name, model} == {"Cmd.store.update", nil}
      assert {id, value} == {uuid(), row.("renamed")}
      assert call(u, "R.id", [cb, uuid()]) == {:ok, var("R.Msg", "Saved", [uuid()])}
    end

    test "store.delete lowers with id and the model from the callback's Option<M>" do
      u = universe(@crud)
      {name, model, [id, cb]} = crud_effect(u, var("R.Msg", "Remove", [uuid()]))
      assert {name, model, id} == {"Cmd.store.delete", "Item.Row", uuid()}
      none = var("Option", "None")
      assert call(u, "R.row", [cb, none]) == {:ok, var("R.Msg", "Removed", [none])}
    end

    test "a store read applied as a value is an error" do
      src =
        @crud <>
          ~S"""
          def R.list_with(read : ((List<Item.Row> -> R.Msg) -> Cmd<R.Msg>)) : Cmd<R.Msg> do read(R.Msg.Loaded) end
          def R.get_with(read : (Uuid, (Option<Item.Row> -> R.Msg) -> Cmd<R.Msg>), id : Uuid) : Cmd<R.Msg> do
            read(id, R.Msg.Got)
          end
          def R.list_read() : Cmd<R.Msg> do R.list_with(Cmd.store.list) end
          def R.get_read(id : Uuid) : Cmd<R.Msg> do R.get_with(Cmd.store.get, id) end
          def R.delete_read(id : Uuid) : Cmd<R.Msg> do R.get_with(Cmd.store.delete, id) end
          """

      u = universe(src)
      why = "reads the model its callback's type names: call it, rather than apply it as a value"

      for {def, args, read} <- [
            {"R.list_read", [], "Cmd.store.list"},
            {"R.get_read", [uuid()], "Cmd.store.get"},
            {"R.delete_read", [uuid()], "Cmd.store.delete"}
          ] do
        assert call(u, def, args) == {:error, "`#{read}` #{why}"}, def
      end
    end
  end

  @json ~S"""
  def J.branch(x : String) : Int do
    case JSON.parse(x) do
      Result.Ok(v) -> v
      Result.Err(e) -> String.length(e)
    end
  end
  def J.apply(f : (String -> Result<Int, String>), x : String) : Result<Int, String> do f(x) end
  def J.parser() : (String -> Result<Int, String>) do JSON.parse end
  """

  describe "JSON" do
    test "a call works as a case scrutinee" do
      u = universe(@json)
      assert call(u, "J.branch", ["42"]) == {:ok, 42}

      for text <- ["not json", ~S("str")] do
        assert {:ok, n} = call(u, "J.branch", [text])
        assert n > 0
      end
    end

    test "JSON.parse applied as a value is Err" do
      u = universe(@json)
      {:ok, parser} = call(u, "J.parser", [])

      assert call(u, "J.apply", [parser, "1"]) ==
               {:ok, err("JSON.parse has no type to decode into when applied as a value")}
    end

    test "JSON.parse decodes into the type its annotation names" do
      assert value(~S|(JSON.parse("[1,2]") : Result<List<Int>, String>)|) == ok([1, 2])
      assert value("(1 + (2 : Int) : Int)") == 3
    end

    test "JSON.parse whose target is open is Err" do
      why = "JSON.parse needs its target type: write (JSON.parse(s) : T)"
      assert value(~S|JSON.parse("[1]")|) == err(why)

      decoded =
        "case JSON.parse(\"[1]\") do\n  Result.Ok(xs) -> List.length(xs)\n  Result.Err(_) -> -1\nend"

      assert value(decoded) == -1
    end

    test "JSON.stringify writes Unit as the empty tuple" do
      assert value("JSON.stringify(always(1 == 1))") == ok("[]")
      assert value("JSON.stringify([sometimes(1 == 2)])") == ok("[[]]")
    end

    test "JSON at the depth limit beneath a deep evaluation" do
      src = """
      deftype A.T do Leaf | Node(A.T) end
      def A.lists(s : String) : Result<List<Int>, String> do JSON.parse(s) end
      def A.chain(n : Int, t : A.T) : A.T do if n == 0 do t else A.chain(n - 1, A.T.Node(t)) end end
      def A.write(n : Int, t : A.T) : Int do
        if n == 0 do
          case JSON.stringify(t) do
            Result.Ok(s) -> String.length(s)
            Result.Err(_) -> 0
          end
        else 0 + A.write(n - 1, t) end
      end
      def A.read(n : Int, s : String) : Int do
        if n == 0 do
          case A.lists(s) do
            Result.Ok(xs) -> List.length(xs)
            Result.Err(e) -> String.length(e)
          end
        else 0 + A.read(n - 1, s) end
      end
      """

      u = universe(src)
      {:ok, chain} = call(u, "A.chain", [99_999, var("A.T", "Leaf")])

      written =
        byte_size(~S|{"$variant":"A.T.Node","values":[]}|) * 99_999 +
          byte_size(~S|{"$variant":"A.T.Leaf","values":[]}|)

      assert call(u, "A.write", [24_500, chain]) == {:ok, written}
      deep = String.duplicate("[", 100_000) <> String.duplicate("]", 100_000)
      assert call(u, "A.read", [24_500, deep]) == {:ok, byte_size("expected Int at $[0]")}
    end
  end
end
