defmodule Kinoko.PersistentElmGenServerTest do
  # The servers run in their own processes, so the sandbox is in shared mode.
  use Kinoko.DataCase, async: false

  alias Kinoko.Elm.Store
  alias Kinoko.PersistentElmGenServer, as: Server

  alias Kinoko.{
    PersistentCounter,
    PersistentCounterUnmigrated,
    PersistentCounterV2,
    PersistentPoison
  }

  @moduletag :capture_log

  defp start(key, opts \\ []), do: start_supervised!({PersistentCounter, [key: key] ++ opts})

  defp start_as(module, key), do: start_supervised!({module, key: key})

  defp stop(key), do: :ok = stop_supervised({PersistentCounter, key})

  defp seqs(key), do: key |> Store.history(1000) |> Enum.map(& &1.seq)

  # start_supervised wraps a failed init as {:error, {{exception, stack}, child}}.
  defp boot_error!(module, key) do
    assert {:error, {{%RuntimeError{message: message}, _stack}, _child}} =
             start_supervised({module, key: key})

    message
  end

  defp await_restart(key, old_pid) do
    Enum.find_value(1..100, fn _ ->
      case Server.whereis(key) do
        pid when is_pid(pid) and pid != old_pid -> pid
        _ -> Process.sleep(10) && nil
      end
    end) || flunk("#{key} was not restarted")
  end

  test "state survives a stop and a restart under the same key" do
    start("c")
    assert Server.call("c", :inc) == 1
    assert Server.call("c", :inc) == 2
    stop("c")

    assert Server.whereis("c") == nil
    start("c")
    assert Server.call("c", :count) == 2
  end

  test "seq continues from the stored one across restarts" do
    start("c")
    Server.call("c", :inc)
    stop("c")
    assert seqs("c") == [1, 0]

    start("c")
    Server.call("c", :inc)
    # resume bumps :resumed (seq 2), then inc (seq 3)
    assert seqs("c") == [3, 2, 1, 0]
  end

  test "a crash under a supervisor resumes the last written state" do
    pid = start("c")
    Server.call("c", :inc)
    Server.call("c", :inc)

    Process.exit(pid, :kill)
    new_pid = await_restart("c", pid)

    assert Server.call(new_pid, :count) == 2
    assert %{resumed: 1} = Server.call("c", :state)
  end

  test "an unchanged state writes no row" do
    start("c")
    Server.call("c", :inc)
    before = seqs("c")

    Server.call("c", :count)
    Server.cast("c", :noop)
    Server.call("c", :state)

    assert seqs("c") == before
  end

  test "the state is written before the step's effects run" do
    start("c")
    Server.cast("c", {:inc_then_send, self()})
    assert_receive {:sent, 1}
    assert {:ok, %{seq: 1}} = Store.latest("c")
  end

  test "keep: 3 prunes to the newest 3 rows" do
    start("c", keep: 3)
    for _ <- 1..5, do: Server.call("c", :inc)

    # init + 5 incs = 6 appends; pruned after the 3rd and the 6th
    assert seqs("c") == [5, 4, 3]
  end

  test "keep defaults to 100" do
    start("c")
    for _ <- 1..199, do: Server.cast("c", :inc)
    assert Server.call("c", :count) == 199

    # init + 199 incs = 200 appends; the prune after the 200th keeps 100
    assert [199 | _] = seqs = seqs("c")
    assert length(seqs) == 100
  end

  test "resume runs on reboot and init does not" do
    start("c", args: [notify: self()])
    assert_receive :init_ran
    refute_received :resumed
    stop("c")

    start("c", args: [notify: self()])
    assert_receive :resumed
    refute_received :init_ran
    assert %{resumed: 1} = Server.call("c", :state)
  end

  test "a version bump calls migrate/2 with the stored version" do
    start("c")
    Server.call("c", :inc)
    stop("c")

    start_as(PersistentCounterV2, "c")
    assert %{count: 1, migrated_from: 1} = Server.call("c", :state)
    assert {:ok, %{version: 2}} = Store.latest("c")
  end

  test "the default migrate/2 refuses to boot, naming the versions" do
    start("c")
    stop("c")

    message = boot_error!(PersistentCounterUnmigrated, "c")
    assert message =~ "Kinoko.PersistentCounterUnmigrated"
    assert message =~ "version 1"
    assert message =~ "migrate/2"
  end

  test "a duplicate key gives :already_started and writes nothing" do
    pid = start("c")
    before = seqs("c")

    assert {:error, {:already_started, ^pid}} =
             Server.start_link(PersistentCounter, [], key: "c")

    assert seqs("c") == before
  end

  test "a stored atom that does not exist fails boot clearly with :safe decoding" do
    # term_to_binary of an atom, built by hand so the atom is never created:
    # 131 = version, 119 = SMALL_ATOM_UTF8_EXT, then length and name
    name = "kinoko_persistent_test_no_such_atom"
    Store.append("c", 0, 1, <<131, 119, byte_size(name), name::binary>>)

    message = boot_error!(PersistentCounter, "c")
    assert message =~ ~s(could not decode the state stored under "c")
    assert message =~ "seq 0"
  end

  # Review Focus 1
  test "a state holding pids, refs and funs survives a restart; stale pids are harmless" do
    gone = spawn(fn -> :ok end)
    start("c")
    Server.cast("c", {:put_extra, %{pid: gone, ref: make_ref(), fun: &(&1 + 1)}})
    Server.call("c", :count)
    stop("c")

    start("c")
    assert %{extra: %{pid: ^gone, ref: ref, fun: fun}} = Server.call("c", :state)
    assert is_reference(ref)
    assert fun.(1) == 2
    refute Process.alive?(gone)
  end

  # Review Focus 3
  test "a store failure mid-step crashes the server, performs no effect, and resumes" do
    pid = start_as(PersistentPoison, "p")
    Server.cast("p", :inc)
    assert Server.call("p", :count) == 1

    ref = Process.monitor(pid)
    Server.cast("p", {:poison_then_send, self()})
    assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{message: msg}, _}}
    assert msg =~ "store is down"
    refute_receive :effect, 100

    new_pid = await_restart("p", pid)
    assert Server.call(new_pid, :count) == 1
  end

  # Review Focus 4
  test "a multi-MB state is written as one row per changed step" do
    start("c")
    big = :crypto.strong_rand_bytes(5_000_000)
    Server.cast("c", {:put_extra, big})
    Server.call("c", :count)
    Server.cast("c", :inc)
    Server.call("c", :count)
    stop("c")

    assert seqs("c") == [2, 1, 0]
    start("c")
    assert %{extra: ^big, count: 1} = Server.call("c", :state)
  end

  # Review Focus 5
  test "a migrated state that fails encode crashes boot with a clear error" do
    Store.append("p", 0, 1, :erlang.term_to_binary(%{count: 3, poison: true}))

    message = boot_error!(PersistentPoison, "p")
    assert message =~ "Kinoko.PersistentPoison.encode/1"
    assert message =~ "store is down"
    assert [%{seq: 0, version: 1}] = Store.history("p")
  end

  test "whereis/1 resolves a key, nil when nothing runs" do
    assert Server.whereis("c") == nil
    pid = start("c")
    assert Server.whereis("c") == pid
  end
end
