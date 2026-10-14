defmodule Kinoko.Elm.SimTest do
  use ExUnit.Case, async: true

  alias Kinoko.Elm.Sim
  alias Kinoko.Examples.SimScenarios

  describe "checkout" do
    test "check-then-pay oversells when two payments land after both checks" do
      result = Sim.explore(SimScenarios.get("checkout_racy"))
      path = Sim.path(result, result.first_violation)

      assert Enum.map(path, & &1.label) == [
               "init",
               "→ call :buy from :alice",
               "→ call :buy from :bob",
               "http POST https://payments.invalid/charge ⇒ 200",
               "http POST https://payments.invalid/charge ⇒ 200"
             ]

      assert List.last(path).violations == ["never oversold", "paid orders ≤ capacity"]
    end

    test "reserve-first holds in every interleaving" do
      result = Sim.explore(SimScenarios.get("checkout_reserve"))
      assert result.stats.violations == 0
      refute result.stats.truncated?
    end

    test "random walks find the race too, reproducibly by seed" do
      assert {:error, run} = Sim.check(SimScenarios.get("checkout_racy"), 1..500)
      assert Sim.run(SimScenarios.get("checkout_racy"), run.seed).violation.id == run.violation.id
    end
  end

  test "url monitor invariants hold on random walks" do
    spec = SimScenarios.get("url_monitor")

    case Sim.check(spec, 1..300) do
      {:ok, 300} -> :ok
      {:error, run} -> flunk("seed #{run.seed}:\n" <> Sim.format_trace(run.trace))
    end
  end
end
