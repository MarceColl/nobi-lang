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

  test "past max_failures failures are only counted, reported as the last entry" do
    max = Hooks.max_failures()
    assert max == 1_000
    for i <- 1..(max + 41), do: Hooks.always_failed("x#{i}")
    failures = Hooks.take_failures()
    assert length(failures) == max + 1
    assert hd(failures) == "always failed: x1"
    assert Enum.at(failures, max - 1) == "always failed: x#{max}"
    assert List.last(failures) == "…and 41 more"
    assert Hooks.take_failures() == []

    for i <- 1..max, do: Hooks.always_failed("y#{i}")
    assert length(Hooks.take_failures()) == max
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
