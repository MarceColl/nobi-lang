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
end
