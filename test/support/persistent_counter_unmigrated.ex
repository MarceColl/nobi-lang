defmodule Kinoko.PersistentCounterUnmigrated do
  @moduledoc "Version 2 of a counter that keeps the default (raising) `migrate/2`."

  use Kinoko.PersistentElmGenServer
  alias Kinoko.Elm.Effect, as: Fx

  @impl true
  def version, do: 2

  @impl true
  def init(_), do: {%{count: 0}, Fx.none()}

  @impl true
  def update({:call, from, :count}, s), do: {s, Fx.reply(from, s.count)}
end
