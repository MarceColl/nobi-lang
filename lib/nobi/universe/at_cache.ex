defmodule Nobi.Universe.AtCache do
  @moduledoc """
  The cache of `Nobi.Universe.at/2`'s pinned views: a public ETS table
  (`read_concurrency`) this process owns, so it lives as long as the
  application. Readers and writers never call the process.

  An entry is `{{universe, commit}, fingerprint, at}`, `fingerprint` the
  hash of the history's first `commit` rounds (ids and CIDs). A lookup
  answers only when the fingerprint matches, so a universe name used again
  with another history (a database reset, a test sandbox) never gets the
  old code back: its entry is rebuilt and replaced. Nothing is evicted.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The fingerprint of `rounds` (history rounds, oldest first)."
  @spec fingerprint([map()]) :: binary()
  def fingerprint(rounds), do: :crypto.hash(:sha256, :erlang.term_to_binary(rounds))

  @doc "The view cached for `{universe, commit}` under `fingerprint`, or `:error`."
  @spec get(String.t(), pos_integer(), binary()) :: {:ok, Nobi.Universe.At.t()} | :error
  def get(universe, commit, fingerprint) do
    case :ets.lookup(@table, {universe, commit}) do
      [{_, ^fingerprint, at}] -> {:ok, at}
      _ -> :error
    end
  rescue
    # The table is gone (the application is stopping): no cache.
    ArgumentError -> :error
  end

  @doc "Caches `at` for `{universe, commit}` under `fingerprint`, replacing any entry."
  @spec put(String.t(), pos_integer(), binary(), Nobi.Universe.At.t()) :: :ok
  def put(universe, commit, fingerprint, at) do
    :ets.insert(@table, {{universe, commit}, fingerprint, at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
