defmodule Kinoko.Exec.HooksTest do
  use ExUnit.Case, async: true

  alias Kinoko.Exec.Hooks

  test "failures are taken in the order recorded, then cleared" do
    assert Hooks.take_failures() == []
    assert Hooks.always_failed("a == 1") == {}
    assert Hooks.always_failed("b") == {}
    assert Hooks.take_failures() == ["always failed: a == 1", "always failed: b"]
    assert Hooks.take_failures() == []
  end

  test "each process records its own" do
    Hooks.always_failed("here")
    task = Task.async(fn -> Hooks.take_failures() end)
    assert Task.await(task) == []
    assert Hooks.take_failures() == ["always failed: here"]
  end

  test "sometimes sites that held are taken once each, then cleared" do
    assert Hooks.take_reached() == MapSet.new()
    assert Hooks.sometimes_held("A.t", "x > 1") == {}
    assert Hooks.sometimes_held("A.t", "x > 1") == {}
    assert Hooks.sometimes_held("A.f", "x > 1") == {}
    assert Hooks.take_reached() == MapSet.new([{"A.t", "x > 1"}, {"A.f", "x > 1"}])
    assert Hooks.take_reached() == MapSet.new()
  end
end
