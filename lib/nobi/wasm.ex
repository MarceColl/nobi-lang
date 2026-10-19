defmodule Nobi.Wasm do
  @moduledoc """
  WASM modules, stored by content and called within hard bounds. The
  language never names this module: `Cmd.wasm.call` is an effect, and the
  hosts perform it through `call/4` (`Nobi.Elm.Effect.wasm/4`).

  ## Modules

  `put/1` stores a module's bytes under `"sha256:<hex>"` in the append-only
  `wasm_modules` table, so code that names a hash always calls the same
  bytes. A module imports nothing (no WASI, no host functions) and exports
  `memory`, `alloc(len : i32) -> ptr : i32` and `free(ptr : i32, len :
  i32)`. A callable export is `(ptr : i32, len : i32) -> i64`: it reads its
  input, UTF-8 text, at `ptr`, and returns its output's `ptr << 32 | len`.
  The caller frees the output with `free`.

  ## Calls

  `call/4` always answers `{:ok, text}` or `{:error, reason}`; it never
  raises, and it never waits past its deadline. Each call gets a fresh
  instance, so a call sees nothing of another. With no imports, a fresh
  instance and fuel counting instructions, the same module, export and
  input always give the same answer, except for `"timeout"` and
  `"wasm busy"`, which depend on the host.

  The bounds, in the order they act (native code cannot be killed from the
  BEAM, so each is enforced by wasmtime or by not starting work):

    1. **Fuel** (`:fuel`) is the hard CPU bound, and deterministic. The
       default, 30 billion, is about 30 s of a tight loop on the reference
       box (about 1e9 fuel per second, measured on `spin`).
    2. **Memory** (`:memory_bytes`, 256 MiB): one instance, one memory and
       one table per store. An allocator that cannot grow aborts with a
       trap, so a trap with memory within 1 MiB of the cap reads as
       `"out of memory"`.
    3. **Concurrency** (`Nobi.Wasm.Pool`): `:concurrency` calls at once
       (default `min(schedulers, 4)`), at most `:queue` (16) waiting. Past
       that a call is `"wasm busy"` at once. A slot is held until the
       native call has really ended.
    4. **Deadline** (`:deadline_ms`, 30 s) covers the wait for a slot and
       the call. Past it the caller gets `"timeout"`, and wasmtime
       interrupts the call (wasmex's epoch interruption).

  Input and output are capped at `:max_input`/`:max_output` (8 MiB each),
  and a module at `:max_module` (32 MiB). Every limit is read from
  `config :nobi, Nobi.Wasm` at call time; `opts` override it per call.

  The errors: `bad module hash`, `unknown module`, `no export <name>`,
  `input too large`, `output too large`, `output out of bounds`, `output is
  not UTF-8`, `trap: …`, `out of fuel`, `out of memory`, `wasm busy`,
  `timeout`, and `wasm is unavailable in this build` (the wasmex NIF did
  not load, as in a build for a target it has no artifact for).
  """

  import Ecto.Query

  alias Nobi.Repo
  alias Nobi.Wasm.{Cache, Pool}

  @mib 1024 * 1024

  @defaults [
    fuel: 30_000_000_000,
    deadline_ms: 30_000,
    memory_bytes: 256 * @mib,
    queue: 16,
    max_input: 8 * @mib,
    max_output: 8 * @mib,
    max_module: 32 * @mib
  ]

  @unavailable "wasm is unavailable in this build"

  @doc "The limits in force: `opts` over `config :nobi, Nobi.Wasm` over the defaults."
  @spec config(keyword()) :: keyword()
  def config(opts \\ []) do
    @defaults
    |> Keyword.put(:concurrency, min(System.schedulers_online(), 4))
    |> Keyword.merge(Application.get_env(:nobi, __MODULE__, []))
    |> Keyword.merge(opts)
  end

  @doc "Whether the wasmex NIF loaded."
  @spec available?() :: boolean()
  def available?, do: Cache.available?()

  @doc """
  Stores `bytes` (a module) and answers its hash and callable exports, in
  name order. Storing the same bytes again is harmless.
  """
  @spec put(binary()) :: {:ok, String.t(), [String.t()]} | {:error, String.t()}
  def put(bytes) when is_binary(bytes) do
    cfg = config()

    cond do
      byte_size(bytes) > cfg[:max_module] ->
        {:error, "module too large (limit #{cfg[:max_module]} bytes)"}

      not available?() ->
        {:error, @unavailable}

      true ->
        with {:ok, module} <- Cache.compile(bytes),
             :ok <- abi(module) do
          hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
          exports = callable(module)

          Repo.insert_all(
            "wasm_modules",
            [
              %{
                hash: hash,
                bytes: bytes,
                exports: Enum.join(exports, ","),
                inserted_at: DateTime.utc_now()
              }
            ],
            on_conflict: :nothing,
            conflict_target: :hash
          )

          Cache.put(hash, module)
          {:ok, hash, exports}
        end
    end
  end

  @doc "A stored module's bytes, or nil."
  @spec bytes(String.t()) :: binary() | nil
  def bytes(hash) when is_binary(hash),
    do: Repo.one(from m in "wasm_modules", where: m.hash == ^hash, select: m.bytes)

  @doc """
  Calls `export` of the module `hash` on `input`, within the bounds (see the
  moduledoc). Never raises.
  """
  @spec call(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def call(hash, export, input, opts \\ []) do
    cfg = config(opts)
    deadline = System.monotonic_time(:millisecond) + cfg[:deadline_ms]

    with :ok <- check_hash(hash),
         :ok <- check_input(input, cfg),
         :ok <- if(available?(), do: :ok, else: {:error, @unavailable}),
         {:ok, module} <- module(hash),
         :ok <- check_export(module, export) do
      Pool.run(fn -> run(module, export, input, cfg, deadline) end, deadline, cfg)
    end
  rescue
    e -> {:error, "wasm: " <> Exception.message(e)}
  catch
    :exit, reason -> {:error, "wasm: " <> Exception.format_exit(reason)}
  end

  defp check_hash("sha256:" <> hex) when byte_size(hex) == 64 do
    if hex =~ ~r/\A[0-9a-f]{64}\z/, do: :ok, else: {:error, "bad module hash"}
  end

  defp check_hash(_), do: {:error, "bad module hash"}

  defp check_input(input, cfg) when is_binary(input) do
    if byte_size(input) > cfg[:max_input], do: {:error, "input too large"}, else: :ok
  end

  defp module(hash) do
    case Cache.get(hash) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        case bytes(hash) do
          nil ->
            {:error, "unknown module"}

          bytes ->
            with {:ok, module} <- Cache.compile(bytes) do
              Cache.put(hash, module)
              {:ok, module}
            end
        end
    end
  end

  defp check_export(module, export) do
    if export in callable(module), do: :ok, else: {:error, "no export #{export}"}
  end

  # The exports a call may name: `(i32, i32) -> i64`.
  defp callable(module) do
    for({name, {:fn, [:i32, :i32], [:i64]}} <- Wasmex.Module.exports(module), do: name)
    |> Enum.sort()
  end

  defp abi(module) do
    exports = Wasmex.Module.exports(module)

    cond do
      Wasmex.Module.imports(module) != %{} ->
        names =
          for {ns, entries} <- Wasmex.Module.imports(module), {n, _} <- entries, do: "#{ns}.#{n}"

        {:error, "a module may import nothing; this one imports #{Enum.join(names, ", ")}"}

      not match?({:memory, _}, exports["memory"]) or
        exports["alloc"] != {:fn, [:i32], [:i32]} or
          exports["free"] != {:fn, [:i32, :i32], []} ->
        {:error,
         "a module exports memory, alloc(len : i32) -> i32 and free(ptr : i32, len : i32)"}

      true ->
        :ok
    end
  end

  # ---------- one call, in a pool runner ----------

  @doc false
  def run(module, export, input, cfg, deadline) do
    limits = %Wasmex.StoreLimits{
      memory_size: cfg[:memory_bytes],
      instances: 1,
      memories: 1,
      tables: 1
    }

    {:ok, store} = Wasmex.Store.new(limits, Cache.engine())
    :ok = Wasmex.StoreOrCaller.set_fuel(store, cfg[:fuel])

    with {:ok, instance} <- instantiate(store, module, cfg),
         {:ok, memory} <- Wasmex.Instance.memory(store, instance) do
      with {:ok, ptr} <- write_input(store, instance, memory, input, deadline),
           {:ok, packed} <- invoke(store, instance, export, [ptr, byte_size(input)], deadline) do
        read_output(store, memory, packed, cfg)
      else
        {:trap, reason} -> {:error, classify(reason, Wasmex.Memory.size(store, memory), cfg)}
        {:error, _} = error -> error
      end
    end
  end

  defp instantiate(store, module, cfg) do
    case Wasmex.Instance.new(store, module, %{}) do
      {:ok, instance} ->
        {:ok, instance}

      {:error, reason} ->
        if reason =~ ~r/memory|limit/i and cfg[:memory_bytes] > 0,
          do: {:error, "out of memory"},
          else: {:error, "trap: " <> short(reason)}
    end
  end

  defp write_input(store, instance, memory, input, deadline) do
    len = byte_size(input)

    with {:ok, ptr} <- invoke(store, instance, "alloc", [len], deadline) do
      if ptr + len > Wasmex.Memory.size(store, memory) do
        {:error, "trap: alloc returned memory out of bounds"}
      else
        :ok = Wasmex.Memory.write_binary(store, memory, ptr, input)
        {:ok, ptr}
      end
    end
  end

  defp read_output(store, memory, packed, cfg) do
    <<ptr::32, len::32>> = <<packed::signed-64>>

    cond do
      len > cfg[:max_output] ->
        {:error, "output too large"}

      ptr + len > Wasmex.Memory.size(store, memory) ->
        {:error, "output out of bounds"}

      true ->
        text = Wasmex.Memory.read_binary(store, memory, ptr, len)

        if String.valid?(text),
          do: {:ok, :binary.copy(text)},
          else: {:error, "output is not UTF-8"}
    end
  end

  # One export call, waiting no longer than `deadline`. wasmex interrupts
  # the call at the deadline and sends nothing; then the store is drained
  # (a call queued behind the interrupted one answers once it has ended),
  # so the pool slot is held until the native call is over.
  defp invoke(store, instance, name, params, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 1)
    ref = make_ref()

    :ok =
      Wasmex.Instance.call_exported_function(store, instance, name, params, {self(), ref}, left)

    receive do
      {^ref, {:ok, [result]}} -> {:ok, result}
      {^ref, {:ok, _}} -> {:error, "trap: #{name} returned the wrong values"}
      {^ref, {:error, reason}} -> {:trap, reason}
    after
      left + 100 ->
        drain(store, instance)
        {:error, "timeout"}
    end
  end

  defp drain(store, instance) do
    ref = make_ref()

    :ok =
      Wasmex.Instance.call_exported_function(store, instance, "free", [0, 0], {self(), ref}, nil)

    receive do
      {^ref, _} -> :ok
    end
  end

  defp classify(reason, memory_size, cfg) do
    cond do
      reason =~ "all fuel consumed" -> "out of fuel"
      memory_size + @mib > cfg[:memory_bytes] -> "out of memory"
      true -> "trap: " <> short(reason)
    end
  end

  defp short(reason) do
    case Regex.run(~r/\(wasm trap: ([^)]*)\)/, reason) do
      [_, why] -> why
      nil -> reason |> String.split("\n") |> hd()
    end
  end
end
