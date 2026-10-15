defmodule Kinoko.PersistentCounterV2 do
  @moduledoc """
  Version 2 of `Kinoko.PersistentCounter`'s state: `migrate/2` records the
  version it migrated from under `:migrated_from`.
  """

  use Kinoko.PersistentElmGenServer
  alias Kinoko.Elm.Effect, as: Fx

  @impl true
  def version, do: 2

  @impl true
  def migrate(state, from), do: Map.put(state, :migrated_from, from)

  @impl true
  def init(_), do: {%{count: 0, migrated_from: nil}, Fx.none()}

  @impl true
  def update({:call, from, :state}, s), do: {s, Fx.reply(from, s)}
end
