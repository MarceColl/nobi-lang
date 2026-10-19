defmodule Nobi.Wasm.Cache do
  @moduledoc """
  The one wasmtime engine every WASM call shares (fuel counting on) and the
  modules compiled with it, in ETS by hash. Filled lazily: `Nobi.Wasm`
  compiles a module from the `wasm_modules` table the first time a call
  names it, so a cold start only costs one compile per module.

  The engine is made on first use, never at boot: when the wasmex NIF did
  not load (a build for a target it has no artifact for), the application
  still starts, and `available?/0` is false.
  """

  use GenServer

  @table __MODULE__
  @engine {__MODULE__, :engine}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Whether the wasmex NIF loaded."
  @spec available?() :: boolean()
  def available? do
    case :persistent_term.get({__MODULE__, :available}, nil) do
      nil ->
        available = Code.ensure_loaded?(Wasmex.Native) and engine_ok?()
        :persistent_term.put({__MODULE__, :available}, available)
        available

      available ->
        available
    end
  end

  defp engine_ok? do
    _ = engine()
    true
  rescue
    _ -> false
  end

  @doc "The shared engine (fuel counting on)."
  @spec engine() :: Wasmex.Engine.t()
  def engine do
    case :persistent_term.get(@engine, nil) do
      nil ->
        config = Wasmex.EngineConfig.consume_fuel(%Wasmex.EngineConfig{}, true)
        {:ok, engine} = Wasmex.Engine.new(config)
        :persistent_term.put(@engine, engine)
        engine

      engine ->
        engine
    end
  end

  @doc "`bytes` compiled with the shared engine."
  @spec compile(binary()) :: {:ok, Wasmex.Module.t()} | {:error, String.t()}
  def compile(bytes) do
    {:ok, store} = Wasmex.Store.new(nil, engine())

    case Wasmex.Module.compile(store, bytes) do
      {:ok, module} -> {:ok, module}
      {:error, reason} -> {:error, "not a WASM module: #{reason |> String.split("\n") |> hd()}"}
    end
  end

  @doc "The compiled module of `hash`, if cached."
  @spec get(String.t()) :: {:ok, Wasmex.Module.t()} | :error
  def get(hash) do
    case :ets.lookup(@table, hash) do
      [{^hash, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @doc "Caches `module` as `hash`'s."
  @spec put(String.t(), Wasmex.Module.t()) :: :ok
  def put(hash, module) do
    :ets.insert(@table, {hash, module})
    :ok
  end

  @doc "Empties the cache (a cold start, for tests)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end
end
