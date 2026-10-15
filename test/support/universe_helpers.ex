defmodule Kinoko.UniverseHelpers do
  @moduledoc """
  Test helpers for `Kinoko.Universe` and `Kinoko.CodeDb`: a fresh universe
  per test whose CodeDb is stopped on exit, and access to its stored rows.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Kinoko.PersistentElmGenServer, as: Server

  @doc "Creates a uniquely named universe and stops its CodeDb on exit."
  def fresh_universe(prefix \\ "t") do
    name = "#{prefix}-#{System.unique_integer([:positive])}"
    :ok = Kinoko.Universe.create(name)
    stop_on_exit(name)
    name
  end

  @doc "Stops the CodeDb of `name` (if running) when the test exits."
  def stop_on_exit(name), do: on_exit(fn -> stop(name) end)

  @doc "Stops the CodeDb of `name` for good (no supervisor restart)."
  def stop(name) do
    case Server.whereis(key(name)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Kinoko.Elm.Supervisor, pid)
    end

    :ok
  end

  def key(name), do: "universe:" <> name

  def pid(name), do: Server.whereis(key(name))

  @doc "Every stored row of `name`'s CodeDb, newest first."
  def rows(name), do: Kinoko.Elm.Store.history(key(name), 1_000)
end
