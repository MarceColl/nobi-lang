defmodule Nobi.ParentWatchTest do
  use ExUnit.Case, async: true

  alias Nobi.ParentWatch

  test "decide/2: orphaned only once the parent pid changed" do
    assert ParentWatch.decide(100, 100) == :ok
    assert ParentWatch.decide(100, nil) == :ok
    assert ParentWatch.decide(100, 1) == :orphaned
    assert ParentWatch.decide(100, 200) == :orphaned
  end

  # A ppid source that answers `values` in turn, then repeats the last.
  defp ppid_seq(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [v | rest] -> {v, rest}
      end)
    end
  end

  test "calls on_orphan once the parent pid changes, and not before" do
    test = self()

    {:ok, _} =
      ParentWatch.start_link(
        name: nil,
        interval: 5,
        ppid: ppid_seq([100, 100, nil, 100, 1]),
        on_orphan: fn -> send(test, :orphaned) end
      )

    assert_receive :orphaned, 1_000
    refute_receive :orphaned, 50
  end

  test "a steady parent never triggers" do
    test = self()

    {:ok, _} =
      ParentWatch.start_link(
        name: nil,
        interval: 5,
        ppid: fn -> 100 end,
        on_orphan: fn -> send(test, :orphaned) end
      )

    refute_receive :orphaned, 100
  end

  test "an unreadable parent pid at start does not start the watch" do
    assert ParentWatch.start_link(name: nil, ppid: fn -> nil end) == :ignore
  end

  test "os_ppid/0 reads this VM's parent pid" do
    assert is_integer(ParentWatch.os_ppid())
  end

  test "maybe_start/1 does nothing outside Burrito" do
    assert ParentWatch.maybe_start(%{}) == :ok
    refute Process.whereis(ParentWatch)
  end
end
