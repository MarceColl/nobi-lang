defmodule Kinoko.Examples.SimScenarios do
  @moduledoc "Named `Kinoko.Elm.Sim` specs, shown in the `/sim` explorer."

  alias Kinoko.Elm.Sim
  alias Kinoko.Examples.Checkout
  alias Kinoko.UrlMonitor

  @doc "`{key, title, description}` for every scenario."
  def list do
    [
      {"checkout_racy", "Checkout · check then pay",
       "Two buyers, one item. Stock is taken only after payment succeeds."},
      {"checkout_reserve", "Checkout · reserve first",
       "Same buyers. The item is reserved before paying and released on failure."},
      {"url_monitor", "UrlMonitor",
       "Polling on a 1s timer while two callers ask for a check and one subscribes."}
    ]
  end

  def get("checkout_racy"), do: checkout(:check_then_pay)
  def get("checkout_reserve"), do: checkout(:reserve_first)

  def get("url_monitor") do
    %{
      module: UrlMonitor,
      init: fn -> UrlMonitor.init(url: "http://monitored.test", interval: 1_000) end,
      inputs: [
        Sim.call(:subscribe, :ops),
        Sim.call(:check_now, :alice),
        Sim.call(:check_now, :bob)
      ],
      invariants: [
        {"callers only wait while a check runs", &(&1.waiting == [] or &1.checking?)},
        {"at most one request in flight",
         fn _s, world -> Enum.count(world.pending, &String.starts_with?(&1, "http")) <= 1 end},
        {"checked implies a status", &(is_nil(&1.checked_at) or &1.status != :unknown)}
      ],
      max_depth: 9
    }
  end

  defp checkout(strategy) do
    %{
      module: Checkout,
      init: fn -> Checkout.init(stock: 1, strategy: strategy) end,
      inputs: [Sim.call(:buy, :alice), Sim.call(:buy, :bob)],
      invariants: [
        {"never oversold", &(&1.stock >= 0)},
        {"paid orders ≤ capacity",
         fn s -> Enum.count(s.orders, fn {_, status} -> status == :paid end) <= s.capacity end}
      ],
      max_depth: 8
    }
  end
end
