defmodule Nobi.Elm.RuntimeInlineTest.Mod do
  alias Nobi.Elm.Effect, as: Fx

  def init, do: {[], Fx.task(fn -> :fetched end, &{:got, &1})}

  def update({:got, {:ok, value}}, acc), do: {[value | acc], Fx.none()}
  def update(:loop, acc), do: {[:loop | acc], Fx.task(fn -> :again end, fn _ -> :loop end)}
  def update({:sub, topic}, acc), do: {acc, Fx.subscribe(Nobi.PubSub, topic, :subscribed)}
  def update(:subscribed, acc), do: {[:subscribed | acc], Fx.none()}
  def update(:wasm, acc), do: {acc, Fx.wasm("sha256:bad", "f", "", &{:wasm, &1})}
  def update({:wasm, r}, acc), do: {[{:wasm, r} | acc], Fx.none()}
end

defmodule Nobi.Elm.RuntimeInlineTest do
  use ExUnit.Case, async: true

  alias Nobi.Elm.Runtime
  alias Nobi.Elm.RuntimeInlineTest.Mod

  test "inline async effects are stepped before init returns, even when not performing" do
    {rt, []} = Runtime.init(Mod, :init, &Mod.init/0, perform: false, inline: 5)
    assert rt.state == [:fetched]
    refute_received _
  end

  test "the budget bounds a chain of async effects; past it they are dropped" do
    {rt, _} = Runtime.init(Mod, :init, &Mod.init/0, perform: false, inline: 4)
    {rt, _} = Runtime.step(rt, :loop)
    assert Enum.count(rt.state, &(&1 == :loop)) == 4
    refute_received _
  end

  test "WASM never runs inline: a render drops it, a connected host runs it in a task" do
    {rt, _} = Runtime.init(Mod, :init, &Mod.init/0, perform: false, inline: 32)
    {rt, _} = Runtime.step(rt, :wasm)
    assert rt.state == [:fetched]
    refute_received _

    {rt, _} = Runtime.init(Mod, :init, &Mod.init/0, inline: 32)
    {rt, _} = Runtime.step(rt, :wasm)
    assert rt.state == [:fetched]
    assert_receive {Runtime, _id, {:wasm, {:error, "bad module hash"}}} = msg
    {rt, _} = Runtime.info(rt, msg)
    assert rt.state == [{:wasm, {:error, "bad module hash"}}, :fetched]
  end

  test "stop_inline/1 returns async effects to their own process" do
    {rt, _} = Runtime.init(Mod, :init, &Mod.init/0, inline: 5)
    {rt, _} = rt |> Runtime.stop_inline() |> Runtime.step(:loop)
    assert rt.state == [:loop, :fetched]
    assert_receive {Runtime, _id, :loop}
  end

  test "subscribe subscribes the host and routes its msg back; dropped when not performing" do
    topic = "inline-test-#{System.unique_integer()}"
    {rt, _} = Runtime.init(Mod, :init, &Mod.init/0, perform: false, inline: 1)
    {_rt, _} = Runtime.step(rt, {:sub, topic})
    Phoenix.PubSub.broadcast(Nobi.PubSub, topic, :hello)
    refute_received :hello

    {rt, _} = Runtime.init(Mod, :init, &Mod.init/0, inline: 1)
    {rt, _} = Runtime.step(rt, {:sub, topic})
    assert_receive {Runtime, id, :subscribed}
    {rt, _} = Runtime.info(rt, {Runtime, id, :subscribed})
    assert hd(rt.state) == :subscribed
    Phoenix.PubSub.broadcast(Nobi.PubSub, topic, :hello)
    assert_receive :hello
  end
end
