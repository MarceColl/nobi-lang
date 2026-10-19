defmodule Nobi.Elm.SimWasmTest.Job do
  # A job loop: `:run` starts a WASM call unless one is in flight; its
  # result is counted. `:sloppy` starts one regardless (two in flight).
  alias Nobi.Elm.Effect, as: Fx

  @hash "sha256:" <> String.duplicate("ab", 32)
  def hash, do: @hash

  def init, do: {%{in_flight: 0, ok: [], err: []}, Fx.none()}

  def update(:run, %{in_flight: 0} = s), do: call(s)
  def update(:run, s), do: {s, Fx.none()}
  def update(:sloppy, s), do: call(s)

  def update({:done, {:ok, text}}, s),
    do: {%{s | in_flight: s.in_flight - 1, ok: [text | s.ok]}, Fx.none()}

  def update({:done, {:error, why}}, s),
    do: {%{s | in_flight: s.in_flight - 1, err: [why | s.err]}, Fx.none()}

  defp call(s),
    do: {%{s | in_flight: s.in_flight + 1}, Fx.wasm(@hash, "echo", "go", &{:done, &1})}
end

defmodule Nobi.Elm.SimWasmTest do
  # `wasm_outcomes(:run)` stores a module: not async.
  use Nobi.DataCase, async: false

  alias Nobi.Elm.{Sim, Timeline}
  alias Nobi.Elm.Effect, as: Fx
  alias Nobi.Elm.SimWasmTest.Job

  defp spec(inputs, extra \\ %{}) do
    Map.merge(
      %{
        module: Job,
        init: &Job.init/0,
        inputs: inputs,
        invariants: [{"never two calls in flight", &(&1.in_flight <= 1)}]
      },
      extra
    )
  end

  defp leaves(result),
    do: for({_, %{status: :done, state: s}} <- result.nodes, do: s)

  test "a WASM request is described without its input" do
    assert Timeline.describe(Fx.wasm(Job.hash(), "echo", "go", & &1)) ==
             "wasm sha256:abababab… echo (2 bytes)"
  end

  test "with no stub, a call resolves only to the host's failures" do
    result = Sim.explore(spec([:run, :run]))
    assert result.stats.violations == 0

    errors = result |> leaves() |> Enum.flat_map(& &1.err) |> Enum.uniq() |> Enum.sort()
    assert errors == ["timeout", "wasm busy"]
    assert result |> leaves() |> Enum.all?(&(&1.ok == []))
  end

  test "a recorded map replays results by their arguments, with no module stored" do
    recorded = %{{Job.hash(), "echo", "go"} => {:ok, ~s({"dps": 1.5})}}

    result =
      Sim.explore(spec([:run], %{outcomes: Sim.wasm_outcomes(recorded, host_failures: false)}))

    assert result |> leaves() |> Enum.map(& &1.ok) |> Enum.uniq() == [[~s({"dps": 1.5})]]
    assert Nobi.Wasm.bytes(Job.hash()) == nil
  end

  test "the invariant fails on the branch that starts a second call" do
    recorded = %{{Job.hash(), "echo", "go"} => {:ok, "x"}}
    result = Sim.explore(spec([:sloppy, :sloppy], %{outcomes: Sim.wasm_outcomes(recorded)}))
    assert result.first_violation

    assert List.last(Sim.path(result, result.first_violation)).violations == [
             "never two calls in flight"
           ]
  end

  test "wasm_outcomes(:run) gives what a real call gives" do
    {:ok, bytes} = Wasmex.Wat.to_wasm(File.read!("test/fixtures/wasm/echo.wat"))
    {:ok, hash, _} = Nobi.Wasm.put(bytes)
    outcomes = Sim.wasm_outcomes(:run, host_failures: false)

    assert outcomes.({:wasm, hash, "upper", "go"}, 0) == [{"result", {:ok, "GO"}}]

    assert outcomes.({:wasm, hash, "spin", "go"}, 0) == [
             {"result", Nobi.Wasm.call(hash, "spin", "go")}
           ]

    assert outcomes.(:now, 0) == nil
  end
end
