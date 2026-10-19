defmodule Mix.Tasks.Nobi.Wasm.Put do
  @shortdoc "Stores a WASM module for Cmd.wasm.call and prints its hash"

  @moduledoc """
  Stores a `.wasm` file (or `.wat` text) for `Cmd.wasm.call`:

      mix nobi.wasm.put path/to/sim.wasm

  Prints the module's hash (`sha256:<hex>`, what code names it by) and its
  callable exports. The MCP `put_wasm` tool does the same over the wire;
  this suits large modules and local work. See `Nobi.Wasm` for the ABI.
  """

  use Mix.Task

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start", [])

    bytes = File.read!(path)

    bytes =
      if Path.extname(path) == ".wat" do
        {:ok, wasm} = Wasmex.Wat.to_wasm(bytes)
        wasm
      else
        bytes
      end

    case Nobi.Wasm.put(bytes) do
      {:ok, hash, exports} ->
        Mix.shell().info(hash)
        Mix.shell().info("exports: " <> Enum.join(exports, ", "))

      {:error, why} ->
        Mix.raise("not stored: " <> why)
    end
  end

  def run(_args), do: Mix.raise("usage: mix nobi.wasm.put path/to/module.wasm")
end
