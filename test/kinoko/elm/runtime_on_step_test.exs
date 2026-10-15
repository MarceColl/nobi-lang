defmodule Kinoko.Elm.RuntimeOnStepTest.Mod do
  alias Kinoko.Elm.Effect, as: Fx

  def init, do: {0, Fx.none()}
  def update(:inc, n), do: {n + 1, Fx.none()}
  def update({:inc_then_ping, pid}, n), do: {n + 1, Fx.send_to(pid, :effect)}
end

defmodule Kinoko.Elm.RuntimeOnStepTest do
  use ExUnit.Case, async: true

  alias Kinoko.Elm.Runtime
  alias Kinoko.Elm.RuntimeOnStepTest.Mod

  defp start(hook), do: Runtime.init(Mod, :init, &Mod.init/0, on_step: hook)

  test "the hook sees every state in order, init included" do
    test_pid = self()
    {rt, _} = start(fn state, seq -> send(test_pid, {:hooked, state, seq}) end)
    {rt, _} = Runtime.step(rt, :inc)
    {_rt, _} = Runtime.step(rt, :inc)

    assert_received {:hooked, 0, 0}
    assert_received {:hooked, 1, 1}
    assert_received {:hooked, 2, 2}
  end

  test "the hook runs before the step's effects" do
    test_pid = self()
    {rt, _} = start(fn _state, seq -> send(test_pid, {:hooked, seq}) end)
    {_rt, _} = Runtime.step(rt, {:inc_then_ping, test_pid})

    assert {:messages, [{:hooked, 0}, {:hooked, 1}, :effect]} =
             Process.info(self(), :messages)
  end

  test "a raising hook prevents the effect" do
    test_pid = self()
    {rt, _} = start(fn _state, seq -> if seq > 0, do: raise("boom") end)

    assert_raise RuntimeError, "boom", fn ->
      Runtime.step(rt, {:inc_then_ping, test_pid})
    end

    refute_received :effect
  end

  test "time travel does not change what the hook sees" do
    test_pid = self()
    {rt, _} = start(fn state, seq -> send(test_pid, {:hooked, state, seq}) end)
    {rt, _} = Runtime.step(rt, :inc)
    {:ok, rt} = Runtime.travel(rt, 0)
    {_rt, _} = Runtime.step(rt, :inc)

    assert_received {:hooked, 2, 2}
  end
end
