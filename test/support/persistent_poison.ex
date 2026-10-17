defmodule Nobi.PersistentPoison do
  @moduledoc """
  A `Nobi.PersistentElmGenServer` whose `encode/1` raises on a state marked
  `poison: true`, standing in for a store failure mid-step. At version 2, its
  `migrate/2` passes a version 1 state through unchanged.
  """

  use Nobi.PersistentElmGenServer
  alias Nobi.Elm.Effect, as: Fx

  @impl true
  def version, do: 2

  @impl true
  def migrate(state, 1), do: state

  @impl true
  def encode(%{poison: true}), do: raise("store is down")
  def encode(state), do: :erlang.term_to_binary(state)

  @impl true
  def init(_), do: {%{count: 0, poison: false}, Fx.none()}

  @impl true
  def update({:call, from, :count}, s), do: {s, Fx.reply(from, s.count)}
  def update(:inc, s), do: {%{s | count: s.count + 1}, Fx.none()}
  def update({:poison_then_send, pid}, s), do: {%{s | poison: true}, Fx.send_to(pid, :effect)}
end
