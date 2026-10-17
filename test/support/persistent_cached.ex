defmodule Nobi.PersistentCached do
  @moduledoc """
  A `Nobi.PersistentElmGenServer` with a volatile `:cache` field:
  `durable/1` drops it, and `decode/1` rebuilds it as `{:rebuilt, count}`.
  """

  use Nobi.PersistentElmGenServer
  alias Nobi.Elm.Effect, as: Fx

  @impl true
  def init(_), do: {%{count: 0, cache: nil}, Fx.none()}

  @impl true
  def durable(state), do: Map.delete(state, :cache)

  @impl true
  def decode(binary) do
    durable = :erlang.binary_to_term(binary, [:safe])
    Map.put(durable, :cache, {:rebuilt, durable.count})
  end

  @impl true
  def update({:call, from, :state}, s), do: {s, Fx.reply(from, s)}
  def update(:inc, s), do: {%{s | count: s.count + 1}, Fx.none()}
  def update({:put_cache, cache}, s), do: {%{s | cache: cache}, Fx.none()}
end
