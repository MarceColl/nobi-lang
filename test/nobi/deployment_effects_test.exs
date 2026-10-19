defmodule Nobi.Deployment.EffectsTest do
  use ExUnit.Case, async: true

  alias Nobi.Deployment.Effects

  @tick {:var, "T.Msg", "Tick", []}

  defp after_ms(ms), do: {:cmd, {:effect, "Cmd.time.after", nil, [ms, @tick]}}

  describe "Cmd.time.after" do
    test "is the delay and the msg itself, from 0 to a day" do
      assert Effects.flatten(after_ms(0)) == {:ok, [{:after, 0, @tick}]}
      assert Effects.flatten(after_ms(86_400_000)) == {:ok, [{:after, 86_400_000, @tick}]}
      assert Effects.describe({:after, 250, @tick}) == "Cmd.time.after(250)"
    end

    test "a delay out of range cannot run" do
      for ms <- [-1, 86_400_001] do
        assert Effects.flatten(after_ms(ms)) ==
                 {:ok, [{:error, "Cmd.time.after: ms must be 0..86400000"}]}
      end
    end

    test "keeps its place in a batch" do
      now = {:effect, "Cmd.time.now", nil, [:cb]}
      cmd = {:cmd, {:batch, [{:effect, "Cmd.time.after", nil, [5, @tick]}, now]}}
      assert Effects.flatten(cmd) == {:ok, [{:after, 5, @tick}, {:now, :cb}]}
    end
  end

  describe "Cmd.wasm.call" do
    defp wasm(args), do: {:cmd, {:effect, "Cmd.wasm.call", nil, args}}

    test "is the module, export and input, and the callback" do
      h = "sha256:" <> String.duplicate("ab", 32)

      assert Effects.flatten(wasm([h, "simulate", "{}", :cb])) ==
               {:ok, [{:wasm, h, "simulate", "{}", :cb}]}

      assert Effects.describe({:wasm, h, "simulate", "{}", :cb}) ==
               "Cmd.wasm.call(sha256:abababab…, simulate)"
    end

    test "a bad hash still runs: its Err reaches the app" do
      assert Effects.flatten(wasm(["nope", "f", "", :cb])) ==
               {:ok, [{:wasm, "nope", "f", "", :cb}]}
    end

    test "its answer is a Result" do
      assert Effects.result({:ok, "out"}) == {:var, "Result", "Ok", ["out"]}
      assert Effects.result({:error, "out of fuel"}) == {:var, "Result", "Err", ["out of fuel"]}
    end
  end
end
