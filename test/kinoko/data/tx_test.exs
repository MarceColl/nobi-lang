defmodule Kinoko.Data.TxTest do
  @moduledoc """
  Closure transactions (store piece, Task 4): `Kinoko.Data.Tx.run/4`'s
  coordinator, against real files and pools (no sandbox). Bodies are
  compiled Yabu closures where the point is the integration, and plain
  Elixir funs (calling `Kinoko.Data.Hooks` as compiled `Store.get` does)
  where a test needs to block, crash or report its handle.
  """
  # Loads images: not async (as the other image tests).
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Kinoko.Data
  alias Kinoko.Data.{Cache, Hooks, Tx}
  alias Kinoko.{Exec, Lang}

  @src ~S"""
  defmodel T.Counter do
    id : Uuid
    n : Int
  end
  defmodel T.Note do
    id : Uuid
    text : String
  end
  deftype T.Msg do Done(Result<(List<Uuid>, Int), String>) end
  def T.incr(id : Uuid) : Cmd<T.Msg> do
    Cmd.store.tx(
      fn (s : Store) ->
        case Store.get(s, id) do
          Option.Some(c) -> ([Tx.update(id, %T.Counter{c | n: c.n + 1})], c.n + 1)
          Option.None -> ([], 0)
        end
      end,
      T.Msg.Done
    )
  end
  def T.add_two(text : String) : Cmd<T.Msg> do
    Cmd.store.tx(
      fn (s : Store) ->
        ([Tx.insert(%T.Note{text: text}), Tx.insert(%T.Note{text: String.concat(text, "!")})],
         List.length((Store.list(s) : List<T.Note>)))
      end,
      T.Msg.Done
    )
  end
  """

  setup_all do
    {u, r} = Lang.stage(Lang.new(), "t", @src)
    {:promoted, _} = r
    {:ok, image} = Exec.load(Lang.snapshot(u))
    %{image: image, models: image.module.__yabu__(:models)}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "kinoko-tx-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Data.close("app", dir: dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp open!(dir, opts \\ []) do
    {:ok, repo} = Data.open("app", [dir: dir] ++ opts)
    repo
  end

  defp tx_body(image, name, args) do
    {:ok, {:cmd, {:effect, "Cmd.store.tx", nil, [body, _cb]}}} = Exec.call(image, name, args)
    body
  end

  defp note(text), do: {:rec, "T.Note", %{"text" => text}}
  defp counter(n), do: {:rec, "T.Counter", %{"n" => n}}

  defp notes(repo, models) do
    {:ok, rows} = Data.list(repo, "T.Note", models)
    for {:rec, _, %{"text" => t}} <- rows, do: t
  end

  # A raw connection holding the file's write lock until released.
  defp hold_lock(dir) do
    {:ok, conn} = Exqlite.Sqlite3.open(Path.join([dir, "data", "app.db"]))
    :ok = Exqlite.Sqlite3.execute(conn, "BEGIN IMMEDIATE")
    conn
  end

  defp release(conn) do
    :ok = Exqlite.Sqlite3.execute(conn, "ROLLBACK")
    Exqlite.Sqlite3.close(conn)
  end

  describe "a Yabu body" do
    test "inserts come back as ids, in order; the body sees the pre-transaction rows",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      {:ok, _} = Data.insert(repo, "T.Note", models, note("old"))
      body = tx_body(image, "T.add_two", ["hi"])

      assert {:ok, {[{:uuid, a}, {:uuid, b}], 1}} = Tx.run(repo, image, body, [])
      assert notes(repo, models) == ["old", "hi", "hi!"]

      assert {:ok, {:rec, _, %{"text" => "hi"}}} = Data.get(repo, "T.Note", models, {:uuid, a})
      assert {:ok, {:rec, _, %{"text" => "hi!"}}} = Data.get(repo, "T.Note", models, {:uuid, b})
    end

    test "reads and updates in one transaction", %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "T.Counter", models, counter(4))

      assert {:ok, {[], 5}} = Tx.run(repo, image, tx_body(image, "T.incr", [id]), [])
      assert {:ok, {:rec, _, %{"n" => 5}}} = Data.get(repo, "T.Counter", models, id)
    end

    test "Review Focus 2: 20 concurrent increments of one row make exactly 20",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "T.Counter", models, counter(0))
      body = tx_body(image, "T.incr", [id])

      results =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> Tx.run(repo, image, body, timeout: 30_000) end) end)
        |> Task.await_many(60_000)

      seen = for {:ok, {[], n}} <- results, do: n
      assert Enum.sort(seen) == Enum.to_list(1..20), inspect(results)
      assert {:ok, {:rec, _, %{"n" => 20}}} = Data.get(repo, "T.Counter", models, id)
    end
  end

  describe "ops" do
    test "an update of a missing id is an error, and rolls back the ops before it",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      missing = {:uuid, Ecto.UUID.generate()}

      body = fn _s ->
        {[{:tx, :insert, "T.Note", note("a")}, {:tx, :update, "T.Note", missing, note("b")}], 0}
      end

      assert {:error, message} = Tx.run(repo, image, body, [])
      assert message =~ "no row with id"
      assert notes(repo, models) == []
    end

    test "a delete removes the row; a delete of a missing id does nothing",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "T.Note", models, note("a"))
      missing = {:uuid, Ecto.UUID.generate()}

      body = fn _s ->
        {[{:tx, :delete, "T.Note", id}, {:tx, :delete, "T.Note", missing}], :done}
      end

      assert {:ok, {[], :done}} = Tx.run(repo, image, body, [])
      assert notes(repo, models) == []
    end

    test "an op whose model never settled is refused, and nothing runs",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)

      body = fn _s ->
        {[{:tx, :insert, "T.Note", note("a")}, {:tx, :insert, nil, note("b")}], 0}
      end

      assert {:error, message} = Tx.run(repo, image, body, [])
      assert message =~ "never settled"
      assert notes(repo, models) == []
    end

    test "a read whose model never settled is an error", %{dir: dir, image: image} do
      repo = open!(dir)
      body = fn s -> {[], Hooks.store_list(s, nil)} end
      assert {:error, message} = Tx.run(repo, image, body, [])
      assert message =~ "never settled"
    end

    test "a body answering something not (ops, r) is an error", %{dir: dir, image: image} do
      repo = open!(dir)
      assert {:error, message} = Tx.run(repo, image, fn _ -> :nope end, [])
      assert message =~ "Tx"
    end
  end

  describe "failures roll back" do
    test "a body that throws a runtime error", %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      body = fn s -> Hooks.store_list(s, "T.Note") && throw({:yabu_error, "division by zero"}) end
      assert {:error, "division by zero"} = Tx.run(repo, image, body, [])
      assert notes(repo, models) == []
    end

    test "a body that crashes: generic message, lock released",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      body = fn _ -> raise "boom with internals" end
      assert {:error, message} = Tx.run(repo, image, body, [])
      refute message =~ "internals"
      assert {:ok, _} = Data.insert(repo, "T.Note", models, note("after"))
    end

    test "a body past the timeout: rolled back, lock released",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      body = fn _ -> Process.sleep(:infinity) end
      {micros, result} = :timer.tc(fn -> Tx.run(repo, image, body, timeout: 100) end)
      assert {:error, message} = result
      assert message =~ "100 ms"
      assert micros < 2_000_000
      assert {:ok, _} = Data.insert(repo, "T.Note", models, note("after"))
    end

    test "the handle is closed once the body returns", %{dir: dir, image: image} do
      repo = open!(dir)
      assert {:ok, {[], handle}} = Tx.run(repo, image, fn s -> {[], s} end, [])

      assert catch_throw(Hooks.store_list(handle, "T.Note")) ==
               {:yabu_error, "store handle used outside its transaction"}
    end

    test "a read of a handle from another transaction is answered closed",
         %{dir: dir, image: image} do
      repo = open!(dir)
      test = self()

      body = fn {:store, coordinator, _} ->
        send(test, {:coordinator, coordinator, self()})

        receive do
          :go -> {[], :ok}
        end
      end

      task = Task.async(fn -> Tx.run(repo, image, body, timeout: 5_000) end)
      assert_receive {:coordinator, coordinator, worker}

      # Same coordinator, another transaction's ref: never a read.
      assert catch_throw(Hooks.store_list({:store, coordinator, make_ref()}, "T.Note")) ==
               {:yabu_error, "store handle used outside its transaction"}

      send(worker, :go)
      assert {:ok, {[], :ok}} = Task.await(task)
    end
  end

  describe "busy and killed" do
    test "a busy file is retried", %{dir: dir, image: image, models: models} do
      repo = open!(dir, busy_timeout: 50)
      :ok = Data.ensure(repo, "T.Note", models)
      conn = hold_lock(dir)
      spawn(fn -> Process.sleep(120) && release(conn) end)

      body = fn _ -> {[{:tx, :insert, "T.Note", note("a")}], 0} end
      assert {:ok, {[_], 0}} = Tx.run(repo, image, body, [])
      assert notes(repo, models) == ["a"]
    end

    test "a file busy past every retry is unavailable", %{dir: dir, image: image, models: models} do
      repo = open!(dir, busy_timeout: 20)
      :ok = Data.ensure(repo, "T.Note", models)
      conn = hold_lock(dir)

      try do
        body = fn _ -> {[{:tx, :insert, "T.Note", note("a")}], 0} end
        assert {:error, message} = Tx.run(repo, image, body, [])
        assert message =~ "busy"
      after
        release(conn)
      end

      assert notes(repo, models) == []
    end

    test "Review Focus 1: a coordinator killed mid-transaction frees the lock at once",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      :ok = Data.ensure(repo, "T.Note", models)
      test = self()

      body = fn {:store, coordinator, _} = s ->
        _ = Hooks.store_list(s, "T.Note")
        send(test, {:coordinator, coordinator})
        Process.sleep(:infinity)
      end

      task = Task.async(fn -> Tx.run(repo, image, body, timeout: 30_000) end)
      assert_receive {:coordinator, coordinator}, 5_000
      Process.exit(coordinator, :kill)
      assert {:error, _} = Task.await(task)

      {micros, result} =
        :timer.tc(fn -> Data.insert(repo, "T.Note", models, note("after")) end)

      assert {:ok, _} = result
      assert micros < 1_000_000, "took #{div(micros, 1000)} ms"
    end

    test "the caller dying ends the transaction", %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      :ok = Data.ensure(repo, "T.Note", models)
      test = self()

      body = fn {:store, coordinator, _} ->
        send(test, {:coordinator, coordinator})
        Process.sleep(:infinity)
      end

      caller = spawn(fn -> Tx.run(repo, image, body, timeout: 30_000) end)
      assert_receive {:coordinator, coordinator}, 5_000
      mon = Process.monitor(coordinator)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^mon, _, _, _}, 2_000

      {micros, result} =
        :timer.tc(fn -> Data.insert(repo, "T.Note", models, note("after")) end)

      assert {:ok, _} = result
      assert micros < 1_000_000
    end
  end

  describe "the schema cache" do
    test "a layout synced inside a committed transaction is cached",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      body = fn _ -> {[{:tx, :insert, "T.Note", note("a")}], 0} end
      assert {:ok, _} = Tx.run(repo, image, body, [])

      fields = Map.fetch!(models, "T.Note")
      key = {repo, "T.Note", :erlang.phash2(fields, 4_294_967_296)}
      assert {:ok, {^fields, %{table: "t__note"}}} = Cache.get(key)
    end

    test "a layout synced inside a rolled-back transaction is not",
         %{dir: dir, image: image, models: models} do
      repo = open!(dir)
      missing = {:uuid, Ecto.UUID.generate()}

      body = fn _ ->
        {[{:tx, :insert, "T.Note", note("a")}, {:tx, :update, "T.Note", missing, note("b")}], 0}
      end

      assert {:error, _} = Tx.run(repo, image, body, [])
      fields = Map.fetch!(models, "T.Note")
      assert :error = Cache.get({repo, "T.Note", :erlang.phash2(fields, 4_294_967_296)})
      assert notes(repo, models) == []
    end
  end
end
