defmodule Kinoko.Data.Cache do
  @moduledoc """
  The schema cache of `Kinoko.Data`: a public ETS table this process owns,
  so it lives as long as the application. Callers never call the process.

  An entry is `{{repo, model, sig_hash}, layout}`: the layout
  (`Kinoko.Data.Schema`) `ensure` made sure of for that model and signature
  in that repo instance's file. Keying by the repo pid scopes an entry to
  one open of the file; its opener drops its entries when it stops
  (`drop/1`).
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The layout cached for `key`, or `:error`."
  @spec get(term()) :: {:ok, term()} | :error
  def get(key) do
    case :ets.lookup(@table, key) do
      [{_, layout}] -> {:ok, layout}
      [] -> :error
    end
  rescue
    # The table is gone (the application is stopping): no cache.
    ArgumentError -> :error
  end

  @doc "Caches `layout` under `key`."
  @spec put(term(), term()) :: :ok
  def put(key, layout) do
    :ets.insert(@table, {key, layout})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops every entry of `repo`."
  @spec drop(pid()) :: :ok
  def drop(repo) do
    :ets.match_delete(@table, {{repo, :_, :_}, :_})
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
