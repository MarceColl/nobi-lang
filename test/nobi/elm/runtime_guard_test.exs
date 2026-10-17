defmodule Nobi.Elm.RuntimeGuardTest.Mod do
  alias Nobi.Elm.Effect, as: Fx

  def init, do: {[], Fx.none()}

  def update(:fetch, acc), do: {acc, Fx.task(fn -> :x end, &{:got, &1})}
  def update(:bad_to_msg, acc), do: {acc, Fx.task(fn -> :x end, fn _ -> raise "boom" end)}
  def update(:throw_to_msg, acc), do: {acc, Fx.now(fn _ -> throw(:nope) end)}
  def update({:sub, t}, acc), do: {acc, Fx.subscribe(Nobi.PubSub, t)}
  def update({:unsub, t}, acc), do: {acc, Fx.unsubscribe(Nobi.PubSub, t)}
  def update(msg, acc), do: {[msg | acc], Fx.none()}
end

defmodule Nobi.Elm.RuntimeGuardTest do
  use ExUnit.Case, async: true

  alias Nobi.Elm.Runtime
  alias Nobi.Elm.RuntimeGuardTest.Mod

  describe "timeline_limit" do
    test "0 keeps no timeline (no state snapshots), effects still come back" do
      {rt, _} = Runtime.init(Mod, :init, &Mod.init/0, timeline_limit: 0)
      {rt, _} = Runtime.step(rt, :a)
      {rt, _} = Runtime.step(rt, :fetch)
      assert Runtime.timeline(rt) == []

      assert_receive {Runtime, _id, _} = msg
      {rt, _} = Runtime.info(rt, msg)
      assert rt.state == [{:got, {:ok, :x}}, :a]
      assert Runtime.timeline(rt) == []
      assert rt.seq == 3
    end

    test "1 keeps only the latest entry" do
      {rt, _} = Runtime.init(Mod, :init, &Mod.init/0, timeline_limit: 1)
      {rt, _} = Runtime.step(rt, :a)
      {rt, _} = Runtime.step(rt, :b)
      assert [%{kind: :msg, msg: :b}] = Runtime.timeline(rt)
    end

    test "the default keeps every step's snapshot" do
      {rt, _} = Runtime.init(Mod, :init, &Mod.init/0)
      {rt, _} = Runtime.step(rt, :a)
      assert [%{seq: 0}, %{seq: 1, state: [:a]}] = Runtime.timeline(rt)
    end
  end

  describe "a raising to_msg" do
    test "produces an effect_error msg from the effect's task" do
      {rt, _} = Runtime.init(Mod, :init, &Mod.init/0)
      {rt, _} = Runtime.step(rt, :bad_to_msg)
      assert_receive {Runtime, _id, {:effect_error, "task " <> _, %RuntimeError{}}} = msg
      {rt, _} = Runtime.info(rt, msg)
      assert [{:effect_error, _, %RuntimeError{message: "boom"}}] = rt.state
    end

    test "produces an effect_error msg inline, without crashing the caller" do
      {rt, _} = Runtime.init(Mod, :init, &Mod.init/0, inline: 2, perform: false)
      {rt, _} = Runtime.step(rt, :throw_to_msg)
      assert [{:effect_error, "now", {:throw, :nope}}] = rt.state
    end
  end

  test "unsubscribe undoes subscribe" do
    topic = "guard-#{System.unique_integer()}"
    {rt, _} = Runtime.init(Mod, :init, &Mod.init/0)
    {rt, _} = Runtime.step(rt, {:sub, topic})
    Phoenix.PubSub.broadcast(Nobi.PubSub, topic, :one)
    assert_receive :one
    {_rt, _} = Runtime.step(rt, {:unsub, topic})
    Phoenix.PubSub.broadcast(Nobi.PubSub, topic, :two)
    refute_receive :two, 50
  end
end
