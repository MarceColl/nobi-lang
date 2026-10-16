defmodule Kinoko.Lang.StoreCodegenTest do
  @moduledoc """
  Store effects compiled (store piece, Task 2): the effect values, the
  `Tx.Op` values, `Store.get`/`Store.list` going through
  `Kinoko.Data.Hooks` with the model the checker settled, and the image's
  model table with its defaults.
  """
  # Loads images: not async.
  use ExUnit.Case, async: false

  alias Kinoko.Exec
  alias Kinoko.Lang

  @id "0b9e2c4a-1f3d-4e5f-8a7b-6c5d4e3f2a1b"

  @src ~S"""
  deftype A.Mode do Off | On(Int) end
  deftype A.Msg do
    Saved(Uuid) | Rows(List<A.Post>) | Row(Option<A.Post>) | Done(Result<(List<Uuid>, Int), String>)
  end
  defmodel A.Post do
    id : Uuid
    n : Int
    tags : List<String> = ["a", "b"]
    hits : Int = -3
    mode : A.Mode = A.Mode.On(2)
    note : Option<String> = Option.None
    meta : Map<String, Int> = %{"k" => 1}
    pair : (Int, Bool) = (1, true)
  end
  def A.post() : A.Post do
    %A.Post{n: 1, tags: [], hits: 0, mode: A.Mode.Off, note: Option.None, meta: %{}, pair: (0, false)}
  end
  def A.effects(id : Uuid) : List<Cmd<A.Msg>> do
    [
      Cmd.store.insert(A.post(), A.Msg.Saved),
      Cmd.store.list(A.Msg.Rows),
      Cmd.store.get(id, A.Msg.Row),
      Cmd.store.update(id, A.post(), A.Msg.Saved),
      Cmd.store.delete(id, A.Msg.Row)
    ]
  end
  def A.ops(id : Uuid) : List<Tx.Op> do
    [Tx.insert(A.post()), Tx.update(id, A.post()), Tx.delete(A.Post, id)]
  end
  def A.inserts(rows : List<A.Post>) : List<Tx.Op> do List.map(rows, Tx.insert) end
  def A.lists() : List<Cmd<A.Msg>> do List.map([A.Msg.Rows], Cmd.store.list) end
  def A.incr(id : Uuid) : Cmd<A.Msg> do
    Cmd.store.tx(
      fn (s : Store) ->
        case Store.get(s, id) do
          Option.Some(p) -> ([Tx.update(id, %A.Post{p | n: p.n + 1})], p.n + 1)
          Option.None -> ([], List.length((Store.list(s) : List<A.Post>)))
        end
      end,
      A.Msg.Done
    )
  end
  def A.getter(s : Store, id : Uuid) : Option<A.Post> do
    List.foldl([id], Option.None, fn (i : Uuid, acc : Option<A.Post>) -> Store.get(s, i) end)
  end
  """

  defp universe(src) do
    {u, r} = Lang.stage(Lang.new(), "p", src)
    assert {:promoted, _} = r, inspect(r)
    Lang.snapshot(u)
  end

  defp call(u, name, args) do
    assert {:ok, v} = Exec.call(u, name, args), name
    v
  end

  defp uuid, do: {:uuid, @id}
  defp ctor(owner, variant), do: Kinoko.Lang.Rt.ctor(owner, variant, 1)

  defp post do
    {:rec, "A.Post",
     %{
       "n" => 1,
       "tags" => [],
       "hits" => 0,
       "mode" => {:var, "A.Mode", "Off", []},
       "note" => {:var, "Option", "None", []},
       "meta" => %{},
       "pair" => {0, false}
     }}
  end

  # A coordinator that answers each read with `answer.(op)`, and tells the
  # test which reads it was asked.
  defp coordinator(answer) do
    test = self()

    spawn_link(fn ->
      loop = fn loop ->
        receive do
          {:kinoko_store_read, ref, from, op} ->
            send(test, {:asked, op})
            send(from, {:kinoko_store_reply, ref, answer.(op)})
            loop.(loop)
        end
      end

      loop.(loop)
    end)
  end

  describe "effect values" do
    test "every store effect names its model" do
      u = universe(@src)
      msg = &ctor("A.Msg", &1)

      assert call(u, "A.effects", [uuid()]) == [
               {:cmd, {:effect, "Cmd.store.insert", "A.Post", [post(), msg.("Saved")]}},
               {:cmd, {:effect, "Cmd.store.list", "A.Post", [msg.("Rows")]}},
               {:cmd, {:effect, "Cmd.store.get", "A.Post", [uuid(), msg.("Row")]}},
               {:cmd, {:effect, "Cmd.store.update", "A.Post", [uuid(), post(), msg.("Saved")]}},
               {:cmd, {:effect, "Cmd.store.delete", "A.Post", [uuid(), msg.("Row")]}}
             ]
    end

    test "tx carries its body and callback, and no model" do
      u = universe(@src)
      assert {:cmd, {:effect, "Cmd.store.tx", nil, [body, cb]}} = call(u, "A.incr", [uuid()])
      assert is_function(body, 1)
      assert cb == ctor("A.Msg", "Done")
    end

    test "a store effect applied as a value names its model too" do
      u = universe(@src)

      assert call(u, "A.lists", []) == [
               {:cmd, {:effect, "Cmd.store.list", "A.Post", [ctor("A.Msg", "Rows")]}}
             ]
    end
  end

  describe "Tx.Op values" do
    test "insert, update and delete are tagged with their model" do
      u = universe(@src)

      assert call(u, "A.ops", [uuid()]) == [
               {:tx, :insert, "A.Post", post()},
               {:tx, :update, "A.Post", uuid(), post()},
               {:tx, :delete, "A.Post", uuid()}
             ]
    end

    test "Tx.insert applied as a value tags its model" do
      u = universe(@src)
      assert call(u, "A.inserts", [[post()]]) == [{:tx, :insert, "A.Post", post()}]
    end

    test "a Tx op shows as the call that builds it" do
      u = universe(@src)
      [ins, upd, del] = call(u, "A.ops", [uuid()])
      assert Exec.show(ins, nil) =~ ~r/^Tx\.insert\(%A\.Post\{/
      assert Exec.show(upd, nil) =~ ~r/^Tx\.update\(<uuid #{@id}>, %A\.Post\{/
      assert Exec.show(del, nil) == "Tx.delete(A.Post, <uuid #{@id}>)"
    end

    test "Tx ops compare as values" do
      u = universe(@src)
      src = @src <> "def A.same(a : Tx.Op, b : Tx.Op) : Bool do a == b end"
      u2 = universe(src)
      [ins, upd, del] = call(u, "A.ops", [uuid()])
      assert call(u2, "A.same", [ins, ins]) == true
      assert call(u2, "A.same", [ins, upd]) == false
      assert call(u2, "A.same", [del, del]) == true
    end
  end

  describe "Store reads in a transaction body" do
    test "Store.get asks the coordinator for the model's row by id" do
      u = universe(@src)
      {:cmd, {:effect, _, _, [body, _]}} = call(u, "A.incr", [uuid()])
      row = put_elem(post(), 2, Map.put(elem(post(), 2), "id", uuid()))

      store =
        {:store, coordinator(fn _ -> {:ok, {:var, "Option", "Some", [row]}} end), make_ref()}

      assert {:ok, {[op], 2}} = Exec.apply(u, body, [store], [])
      assert_received {:asked, {:get, "A.Post", {:uuid, @id}}}
      assert {:tx, :update, "A.Post", {:uuid, @id}, {:rec, "A.Post", %{"n" => 2}}} = op
    end

    test "Store.list asks the coordinator for the model's rows" do
      u = universe(@src)
      {:cmd, {:effect, _, _, [body, _]}} = call(u, "A.incr", [uuid()])

      answer = fn
        {:get, _, _} -> {:ok, {:var, "Option", "None", []}}
        {:list, _} -> {:ok, [post(), post(), post()]}
      end

      store = {:store, coordinator(answer), make_ref()}
      assert {:ok, {[], 3}} = Exec.apply(u, body, [store], [])
      assert_received {:asked, {:get, "A.Post", _}}
      assert_received {:asked, {:list, "A.Post"}}
    end

    test "Store.get applied in a def's closure names its model" do
      u = universe(@src)
      store = {:store, coordinator(fn _ -> {:ok, {:var, "Option", "None", []}} end), make_ref()}
      assert {:ok, {:var, "Option", "None", []}} = Exec.call(u, "A.getter", [store, uuid()])
      assert_received {:asked, {:get, "A.Post", {:uuid, @id}}}
    end

    test "a handle whose transaction is over is a runtime error" do
      u = universe(@src)
      {:cmd, {:effect, _, _, [body, _]}} = call(u, "A.incr", [uuid()])
      gone = spawn(fn -> :ok end)
      ref = Process.monitor(gone)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert {:error, %{code: "runtime", message: "store handle used outside its transaction"}} =
               Exec.apply(u, body, [{:store, gone, make_ref()}], [])

      closed = {:store, coordinator(fn _ -> :closed end), make_ref()}

      assert {:error, %{code: "runtime", message: "store handle used outside its transaction"}} =
               Exec.apply(u, body, [closed], [])
    end
  end

  describe "the model table" do
    test "each field carries its default's value, :none without one" do
      u = universe(@src)
      {:ok, image} = Exec.load(u)

      assert image.module.__yabu__(:models)["A.Post"] == [
               {"id", {:named, "Uuid"}, :none},
               {"n", {:named, "Int"}, :none},
               {"tags", {:applied, "List", [{:named, "String"}]}, ["a", "b"]},
               {"hits", {:named, "Int"}, -3},
               {"mode", {:named, "A.Mode"}, {:var, "A.Mode", "On", [2]}},
               {"note", {:applied, "Option", [{:named, "String"}]}, {:var, "Option", "None", []}},
               {"meta", {:applied, "Map", [{:named, "String"}, {:named, "Int"}]}, %{"k" => 1}},
               {"pair", {:tuple, [{:named, "Int"}, {:named, "Bool"}]}, {1, true}}
             ]
    end

    test "JSON still reads and writes records through the table" do
      src =
        @src <>
          ~S"""
          defmodel A.Note do
            id : Uuid
            text : String
            n : Int = 7
          end
          def A.round(p : A.Note) : Result<A.Note, String> do
            case JSON.stringify(p) do
              Result.Ok(t) -> JSON.parse(t)
              Result.Err(e) -> Result.Err(e)
            end
          end
          def A.text(p : A.Note) : Result<String, String> do JSON.stringify(p) end
          """

      u = universe(src)
      row = {:rec, "A.Note", %{"id" => uuid(), "text" => "t", "n" => 1}}
      assert call(u, "A.round", [row]) == {:var, "Result", "Ok", [row]}

      assert call(u, "A.text", [row]) ==
               {:var, "Result", "Ok", [~s({"id":"#{@id}","text":"t","n":1})]}
    end
  end
end
