defmodule Kinoko.Universe.EvalLatencyPerfTest do
  # Review item 7: eval on a large universe asks the CodeDb only for its
  # image's hash and signatures once the image is loaded, rather than
  # copying the whole committed code (typed trees included) out per call.
  use Kinoko.DataCase, async: false

  import Kinoko.UniverseHelpers

  alias Kinoko.{CodeDb, Exec, Universe}
  alias Kinoko.PersistentElmGenServer, as: Server

  @moduletag :perf
  @defs 3_000
  @runs 50

  defp median_us(f) do
    f.()

    1..@runs
    |> Enum.map(fn _ -> f |> :timer.tc() |> elem(0) end)
    |> Enum.sort()
    |> Enum.at(div(@runs, 2))
  end

  test "eval on a #{@defs}-def universe: fast path vs whole snapshot" do
    u = fresh_universe("perf")

    source =
      Enum.map_join(0..(@defs - 1), "\n\n", fn i ->
        if i == 0,
          do: "def P.f0() : Int do\n  0\nend",
          else: "def P.f#{i}() : Int do\n  P.f#{i - 1}() + 1\nend"
      end)

    {:promoted, ["big"]} = Universe.stage(u, "big", source)
    {:ok, 10, _} = Universe.eval(u, "P.f10()", [])

    # Today: hash and signatures from the CodeDb, the image already loaded.
    fast = median_us(fn -> {:ok, 10, _} = Universe.eval(u, "P.f10()", []) end)

    # Before: the whole snapshot out of the CodeDb on every eval, the image
    # found again by hashing its committed code.
    slow =
      median_us(fn ->
        {:ok, snapshot} = Server.call(CodeDb.key(u), :snapshot)
        {:ok, 10, _} = Exec.eval(snapshot, "P.f10()", [])
      end)

    IO.puts(
      "\neval latency, #{@defs} defs (median of #{@runs}): " <>
        "fast path #{fast} us, whole snapshot #{slow} us (#{Float.round(slow / fast, 1)}x)"
    )

    assert fast < slow
  end
end
