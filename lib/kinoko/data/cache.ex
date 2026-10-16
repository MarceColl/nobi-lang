defmodule Kinoko.Data.Cache do
  @moduledoc """
  The schema cache of `Kinoko.Data`: a public ETS table this process owns,
  so it lives as long as the application. Callers never call the process.

  An entry is `{{repo, model, sig_hash}, layout}`: the layout
  (`Kinoko.Data.Schema`) `ensure` made sure of for that model and signature
  in that repo instance's file. Keying by the repo pid scopes an entry to
  one open of the file; its opener drops its entries when it stops
  (`drop/1`).

  ## Deferred entries

  A layout synced inside a transaction is valid only if the transaction
  commits. `Kinoko.Data.transaction/2` opens a deferral scope in its
  process (`defer_begin/0`); layouts synced inside it are kept there
  (`defer/2`, read back by `deferred/1` for the rest of the transaction)
  and published to the table after the commit (`defer_publish/0`), or
  dropped on a rollback (`defer_end/0` without publishing). Outside a
  scope, `defer/2` keeps nothing: the next call syncs again.
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

  @deferred {__MODULE__, :deferred}

  @doc "Opens a deferral scope in the calling process (see \"Deferred entries\")."
  @spec defer_begin() :: :ok
  def defer_begin do
    Process.put(@deferred, %{})
    :ok
  end

  @doc "Keeps `layout` for `key` until the scope publishes or ends; nothing outside a scope."
  @spec defer(term(), term()) :: :ok
  def defer(key, layout) do
    case Process.get(@deferred) do
      %{} = pending -> Process.put(@deferred, Map.put(pending, key, layout))
      nil -> :ok
    end

    :ok
  end

  @doc "The layout deferred for `key` in this process's scope, or `:error`."
  @spec deferred(term()) :: {:ok, term()} | :error
  def deferred(key) do
    case Process.get(@deferred) do
      %{^key => layout} -> {:ok, layout}
      _ -> :error
    end
  end

  @doc "Caches every layout deferred in this process's scope (after a commit)."
  @spec defer_publish() :: :ok
  def defer_publish do
    for {key, layout} <- Process.get(@deferred) || %{}, do: put(key, layout)
    :ok
  end

  @doc "Closes this process's scope, dropping what it did not publish."
  @spec defer_end() :: :ok
  def defer_end do
    Process.delete(@deferred)
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
