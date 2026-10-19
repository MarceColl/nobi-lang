defmodule Nobi.WasmTest do
  # Writes `wasm_modules`: not async.
  use Nobi.DataCase, async: false

  alias Nobi.Wasm
  alias Nobi.Wasm.{Cache, Pool}

  @echo File.read!("test/fixtures/wasm/echo.wat")

  defp echo! do
    {:ok, bytes} = Wasmex.Wat.to_wasm(@echo)
    {:ok, hash, _} = Wasm.put(bytes)
    hash
  end

  # Waits until the pool has no runner left (a timed-out call's runner
  # drains its native call first).
  defp idle! do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      if Pool.load().running == 0, do: {:halt, :ok}, else: Process.sleep(20) && {:cont, nil}
    end)
  end

  setup do
    on_exit(fn -> idle!() end)
    :ok
  end

  describe "put" do
    test "stores by content, idempotently, and lists the callable exports" do
      {:ok, bytes} = Wasmex.Wat.to_wasm(@echo)
      hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      assert {:ok, ^hash, exports} = Wasm.put(bytes)
      assert exports == ~w(big echo garble grow spin trap upper)
      assert {:ok, ^hash, ^exports} = Wasm.put(bytes)
      assert Repo.aggregate(from(m in "wasm_modules", where: m.hash == ^hash), :count) == 1
      assert Wasm.bytes(hash) == bytes
    end

    test "refuses imports, a missing ABI, non-WASM and oversized modules" do
      {:ok, imports} =
        Wasmex.Wat.to_wasm(
          ~s|(module (import "env" "f" (func)) (memory (export "memory") 1)| <>
            ~s|(func (export "alloc") (param i32) (result i32) i32.const 0)| <>
            ~s|(func (export "free") (param i32 i32)))|
        )

      assert Wasm.put(imports) == {:error, "a module may import nothing; this one imports env.f"}

      {:ok, bare} = Wasmex.Wat.to_wasm(~s|(module (memory (export "memory") 1))|)

      assert Wasm.put(bare) ==
               {:error,
                "a module exports memory, alloc(len : i32) -> i32 and free(ptr : i32, len : i32)"}

      assert {:error, "not a WASM module: " <> _} = Wasm.put("not wasm")

      env = Application.get_env(:nobi, Wasm)
      Application.put_env(:nobi, Wasm, Keyword.put(env, :max_module, 10))
      on_exit(fn -> Application.put_env(:nobi, Wasm, env) end)
      assert {:error, "module too large" <> _} = Wasm.put(bare)
    end
  end

  describe "call" do
    test "echo and upper round-trip multi-byte UTF-8" do
      h = echo!()

      assert Wasm.call(h, "echo", ~s|{"dps": 1234.5, "who": "猫 👋"}|) ==
               {:ok, ~s|{"dps": 1234.5, "who": "猫 👋"}|}

      assert Wasm.call(h, "upper", "héllo wörld") == {:ok, "HéLLO WöRLD"}
      assert Wasm.call(h, "echo", "") == {:ok, ""}
    end

    test "bad hashes, unknown modules, missing exports and big inputs are errors before any work" do
      h = echo!()
      assert Wasm.call("nope", "echo", "x") == {:error, "bad module hash"}

      assert Wasm.call("sha256:" <> String.duplicate("A", 64), "echo", "x") ==
               {:error, "bad module hash"}

      assert Wasm.call("sha256:" <> String.duplicate("0", 64), "echo", "x") ==
               {:error, "unknown module"}

      assert Wasm.call(h, "nope", "x") == {:error, "no export nope"}
      assert Wasm.call(h, "alloc", "x") == {:error, "no export alloc"}
      assert Wasm.call(h, "echo", "xx", max_input: 1) == {:error, "input too large"}
    end

    test "each runaway ends as its error" do
      h = echo!()
      assert Wasm.call(h, "spin", "x") == {:error, "out of fuel"}
      assert Wasm.call(h, "grow", "x") == {:error, "out of memory"}

      assert Wasm.call(h, "trap", "x") ==
               {:error, "trap: wasm `unreachable` instruction executed"}

      assert Wasm.call(h, "big", "x") == {:error, "output too large"}

      assert Wasm.call(h, "big", "x", max_output: 4 * 1024 * 1024 * 1024) ==
               {:error, "output out of bounds"}

      assert Wasm.call(h, "garble", "abc") == {:error, "output is not UTF-8"}
    end

    test "fuel is deterministic: the same fuel runs out at the same work" do
      h = echo!()
      # `upper` on 2,000 bytes needs more than 10,000 fuel and less than 1,000,000.
      input = String.duplicate("a", 2_000)

      for _ <- 1..2 do
        assert Wasm.call(h, "upper", input, fuel: 10_000) == {:error, "out of fuel"}
        assert Wasm.call(h, "upper", input, fuel: 1_000_000) == {:ok, String.upcase(input)}
      end
    end

    test "the deadline answers timeout on time, and the slot stays busy until the call ends" do
      h = echo!()
      t0 = System.monotonic_time(:millisecond)

      assert Wasm.call(h, "spin", "x", fuel: 1_000_000_000_000, deadline_ms: 100) ==
               {:error, "timeout"}

      assert System.monotonic_time(:millisecond) - t0 < 200
      # wasmex interrupts the call at the deadline; the runner drains it.
      assert :ok = idle!()
    end

    test "a full pool answers wasm busy at once" do
      h = echo!()
      slow = [fuel: 1_000_000_000_000, deadline_ms: 400, concurrency: 1, queue: 0]
      first = Task.async(fn -> Wasm.call(h, "spin", "x", slow) end)
      wait_until(fn -> Pool.load().running == 1 end)

      t0 = System.monotonic_time(:millisecond)
      assert Wasm.call(h, "echo", "x", concurrency: 1, queue: 0) == {:error, "wasm busy"}
      assert System.monotonic_time(:millisecond) - t0 < 100
      assert Task.await(first) == {:error, "timeout"}
    end

    test "a queued call runs once a slot frees" do
      h = echo!()
      opts = [concurrency: 1, queue: 1]
      first = Task.async(fn -> Wasm.call(h, "spin", "x", opts) end)
      wait_until(fn -> Pool.load().running == 1 end)
      assert Wasm.call(h, "echo", "after", opts) == {:ok, "after"}
      assert Task.await(first) == {:error, "out of fuel"}
    end

    test "the cache survives a cold start" do
      h = echo!()
      Cache.clear()
      assert Cache.get(h) == :error
      assert Wasm.call(h, "echo", "cold") == {:ok, "cold"}
      assert {:ok, _} = Cache.get(h)
    end
  end

  defp wait_until(f) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      if f.(), do: {:halt, :ok}, else: Process.sleep(5) && {:cont, nil}
    end)
  end
end
