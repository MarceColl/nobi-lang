defmodule YabuOracle do
  @moduledoc "The TS/Rust golden files, migrated to typed Html. See test/fixtures/yabu/source.json."
  @dir Path.expand("../fixtures/yabu", __DIR__)

  def corpus, do: read("corpus.json")
  def corpus_source(file), do: File.read!(Path.join(@dir, file))
  def generated, do: read("generated.json")
  def ill_typed, do: read("ill_typed.json")

  def every_source do
    gen =
      generated()
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> {"generated[#{i}] seed #{p["seed"]}", p["source"]} end)

    ill =
      ill_typed()
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> {"ill_typed[#{i}] seed #{p["seed"]}", p["source"]} end)

    cor = Enum.map(corpus(), &{&1["file"], corpus_source(&1["file"])})
    gen ++ ill ++ cor
  end

  defp read(file), do: @dir |> Path.join(file) |> File.read!() |> JSON.decode!()
end
