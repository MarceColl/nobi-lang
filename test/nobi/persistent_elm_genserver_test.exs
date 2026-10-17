defmodule Nobi.PersistentElmGenServerTest do
  # The servers run in their own processes, so the sandbox is in shared mode.
  use Nobi.DataCase, async: false

  alias Nobi.Elm.Store
  alias Nobi.PersistentElmGenServer, as: Server

  alias Nobi.{
    PersistentCached,
    PersistentCounter,
    PersistentCounterUnmigrated,
    PersistentCounterV2,
    PersistentPoison,
    PersistentTraced
  }

  @moduletag :capture_log

  defp start(key, opts \\ []), do: start_supervised!({PersistentCounter, [key: key] ++ opts})

  defp start_as(module, key, opts \\ []), do: start_supervised!({module, [key: key] ++ opts})

  defp stop(key), do: :ok = stop_supervised({PersistentCounter, key})

  defp seqs(key), do: key |> Store.history(1000) |> Enum.map(& &1.seq)

  # Appends a row as if `module` had written `state` at `version`.
  defp put_row(module, key, seq, version, state),
    do: Store.append(key, seq, inspect(module), version, :erlang.term_to_binary(state))

  defp counter_state(count), do: %{count: count, resumed: 0, notify: nil, extra: nil}

  defp next_message do
    receive do
      msg -> msg
    after
      1000 -> flunk("no message")
    end
  end

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
    start_as(PersistentTraced, "t", args: self())
    assert next_message() == {:encoding, 0, 0}
    assert next_message() == :init_ran

    Server.cast("t", {:inc_then_send, self()})
    assert next_message() == {:encoding, 1, 0}
    assert next_message() == {:sent, 1}
    assert {:ok, %{seq: 1}} = Store.latest("t")
  end

  test "on boot, the resumed state is written before resume's effects run" do
    start_as(PersistentTraced, "t", args: self())
    assert next_message() == {:encoding, 0, 0}
    assert next_message() == :init_ran
    :ok = stop_supervised({PersistentTraced, "t"})

    start_as(PersistentTraced, "t", args: self())
    assert next_message() == {:encoding, 0, 1}
    assert next_message() == :resumed
    assert seqs("t") == [1, 0]
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

  test "boot prunes to keep, so a crash-looping key stays bounded" do
    for seq <- 0..9, do: put_row(PersistentCounter, "c", seq, 1, counter_state(seq))

    start("c", keep: 3)
    # pruned to 7..9 on boot, then resume writes seq 10
    assert seqs("c") == [10, 9, 8, 7]
    assert Server.call("c", :count) == 9
  end

  test "a failed prune logs a warning and the step's effects still run" do
    Nobi.Repo.query!("""
    CREATE TRIGGER elm_states_refuse_delete BEFORE DELETE ON elm_states
    FOR EACH ROW WHEN OLD.key = 'pf' BEGIN SELECT RAISE(ABORT, 'prune refused'); END
    """)

    pid = start("pf", keep: 2)
    # init + 2 incs = 3 appends; the prune after the 2nd had nothing to delete
    Server.call("pf", :inc)
    Server.call("pf", :inc)

    {reply, log} =
      ExUnit.CaptureLog.with_log(fn ->
        # the 4th append prunes, which would delete 2 rows, and fails
        Server.cast("pf", {:inc_then_send, self()})
        assert_receive {:sent, 3}
        Server.call("pf", :inc)
      end)

    assert reply == 4
    assert log =~ ~s(could not prune "pf" to 2 rows)
    assert log =~ "prune refused"
    assert Server.whereis("pf") == pid
    assert seqs("pf") == [4, 3, 2, 1, 0]
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
    put_row(PersistentCounterV2, "c", 0, 1, %{count: 1})

    start_as(PersistentCounterV2, "c")
    assert %{count: 1, migrated_from: 1} = Server.call("c", :state)
    assert {:ok, %{version: 2}} = Store.latest("c")
  end

  test "the default migrate/2 refuses to boot, naming the versions" do
    put_row(PersistentCounterUnmigrated, "c", 0, 1, %{count: 1})

    message = boot_error!(PersistentCounterUnmigrated, "c")
    assert message =~ "Nobi.PersistentCounterUnmigrated"
    assert message =~ "version 1"
    assert message =~ "migrate/2"
  end

  test "a state stored at a newer version than the module's says so" do
    put_row(PersistentCounter, "c", 0, 5, counter_state(1))

    message = boot_error!(PersistentCounter, "c")
    assert message =~ "version 5"
    assert message =~ "newer than its own version 1"
    assert message =~ "rolled back"
  end

  test "a raise in migrate/2 fails boot with the key, seq and versions" do
    # PersistentPoison (version 2) migrates only from version 1
    put_row(PersistentPoison, "p", 4, 3, %{count: 1, poison: false})

    message = boot_error!(PersistentPoison, "p")
    assert message =~ ~s[could not migrate the state stored under "p" (seq 4)]
    assert message =~ "from version 3 to version 2"
  end

  test "a key written by another module refuses to boot" do
    start("c")
    stop("c")

    message = boot_error!(PersistentCounterV2, "c")
    assert message =~ ~s("c" holds a state written by "Nobi.PersistentCounter")
    assert message =~ "not by Nobi.PersistentCounterV2"
    assert [%{module: "Nobi.PersistentCounter"} | _] = Store.history("c")
  end

  test "only the durable projection is compared and stored" do
    start_as(PersistentCached, "k")
    Server.cast("k", :inc)
    assert %{count: 1} = Server.call("k", :state)
    assert seqs("k") == [1, 0]

    Server.cast("k", {:put_cache, :warm})
    assert %{cache: :warm} = Server.call("k", :state)
    assert seqs("k") == [1, 0]

    assert {:ok, %{state: stored}} = Store.latest("k")
    assert :erlang.binary_to_term(stored) == %{count: 1}

    :ok = stop_supervised({PersistentCached, "k"})
    start_as(PersistentCached, "k")
    assert Server.call("k", :state) == %{count: 1, cache: {:rebuilt, 1}}
    # the rebuilt state's projection equals the stored one: no write on boot
    assert seqs("k") == [1, 0]
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
    name = "nobi_persistent_test_no_such_atom"

    Store.append(
      "c",
      0,
      "Nobi.PersistentCounter",
      1,
      <<131, 119, byte_size(name), name::binary>>
    )

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
    put_row(PersistentPoison, "p", 0, 1, %{count: 3, poison: true})

    message = boot_error!(PersistentPoison, "p")
    assert message =~ "Nobi.PersistentPoison.encode/1"
    assert message =~ "store is down"
    assert [%{seq: 0, version: 1}] = Store.history("p")
  end

  test "start/3 runs the server under Nobi.Elm.Supervisor, which restarts it" do
    on_exit(fn ->
      if pid = Server.whereis("sup"),
        do: DynamicSupervisor.terminate_child(Nobi.Elm.Supervisor, pid)
    end)

    assert {:ok, pid} = Server.start(PersistentCounter, [], key: "sup")
    assert {:error, {:already_started, ^pid}} = Server.start(PersistentCounter, [], key: "sup")
    assert {:undefined, pid, :worker, [Nobi.PersistentElmGenServer]} in children()

    Server.call("sup", :inc)
    Server.call("sup", :inc)
    Process.exit(pid, :kill)

    new_pid = await_restart("sup", pid)
    assert {:undefined, new_pid, :worker, [Nobi.PersistentElmGenServer]} in children()
    assert Server.call("sup", :count) == 2
    assert %{resumed: 1} = Server.call("sup", :state)

    :ok = DynamicSupervisor.terminate_child(Nobi.Elm.Supervisor, new_pid)
  end

  defp children, do: DynamicSupervisor.which_children(Nobi.Elm.Supervisor)

  test "a caller that starts a crashed key before the supervisor's restart wins; the restart is dropped" do
    sup = Process.whereis(Nobi.Elm.Supervisor)

    on_exit(fn ->
      if pid = Server.whereis("race"), do: Process.exit(pid, :kill)
    end)

    assert {:ok, pid} = Server.start(PersistentCounter, [], key: "race")
    Server.call("race", :inc)

    # Hold the supervisor's restart back until the caller has started the key.
    :ok = :sys.suspend(sup)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    Enum.find(1..100, fn _ -> Server.whereis("race") == nil or Process.sleep(5) end)

    test = self()

    holder =
      spawn(fn ->
        {:ok, mine} = Server.start_link(PersistentCounter, [], key: "race")
        send(test, {:started, mine})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, mine}
    on_exit(fn -> Process.exit(holder, :kill) end)

    :ok = :sys.resume(sup)

    # The supervisor handled the crash (its mailbox is in order) and is alive.
    children = children()
    assert Process.whereis(Nobi.Elm.Supervisor) == sup
    refute Enum.any?(children, fn {_, child, _, _} -> child in [pid, :restarting] end)

    # Exactly one server serves the key: the caller's, with the stored state.
    Process.sleep(50)
    assert Process.whereis(Nobi.Elm.Supervisor) == sup
    assert Server.whereis("race") == mine
    assert Server.call("race", :count) == 1
    assert Registry.lookup(Nobi.Elm.Registry, "race") == [{mine, nil}]
  end

  test "a supervisor restart that fails to boot is dropped and logged, not retried" do
    sup = Process.whereis(Nobi.Elm.Supervisor)

    on_exit(fn ->
      if pid = Server.whereis("doomed"), do: Process.exit(pid, :kill)
    end)

    assert {:ok, pid} = Server.start(PersistentCounter, [], key: "doomed")
    Server.call("doomed", :inc)
    # The row now belongs to another module, so the restart refuses to boot.
    put_row(PersistentCached, "doomed", 5, 1, %{})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
        Process.sleep(100)
        refute Enum.any?(children(), fn {_, child, _, _} -> child == :restarting end)
      end)

    assert log =~ "could not boot again"
    assert Process.whereis(Nobi.Elm.Supervisor) == sup
    assert Server.whereis("doomed") == nil

    # The next start/3 is a first start: its caller gets the boot error.
    assert {:error, {%RuntimeError{message: message}, _}} =
             Server.start(PersistentCounter, [], key: "doomed")

    assert message =~ "Nobi.PersistentCached"
  end

  test "an unsupported host effect names PersistentElmGenServer" do
    pid = start("c")
    ref = Process.monitor(pid)
    Server.cast("c", {:effect, Nobi.Elm.Effect.navigate("/x")})

    assert_receive {:DOWN, ^ref, :process, ^pid, {%ArgumentError{message: message}, _}}
    assert message == ~s({:navigate, "/x"} is not supported in a PersistentElmGenServer)
  end

  test "whereis/1 resolves a key, nil when nothing runs" do
    assert Server.whereis("c") == nil
    pid = start("c")
    assert Server.whereis("c") == pid
  end
end
