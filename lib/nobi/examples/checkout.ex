defmodule Nobi.Examples.Checkout do
  @moduledoc """
  Sells a limited stock, charging a payment provider over HTTP. The example
  `Nobi.Elm.Sim` scenarios run against.

  Two strategies:

    * `:check_then_pay` — checks stock, pays, and takes the item once paid.
      Two buyers can both pass the check while their payments are in flight,
      so it oversells. Each update is correct on its own; the bug only exists
      in an interleaving.
    * `:reserve_first` — takes the item before paying and puts it back if the
      payment fails.
  """

  use Nobi.ElmGenServer
  alias Nobi.Elm.Effect, as: Fx

  @payments_url "https://payments.invalid/charge"

  def start_link(opts), do: Nobi.ElmGenServer.start_link(__MODULE__, opts)

  def buy(server), do: Nobi.ElmGenServer.call(server, :buy, 15_000)

  @impl true
  def init(opts) do
    stock = Keyword.get(opts, :stock, 1)

    state = %{
      capacity: stock,
      stock: stock,
      strategy: Keyword.get(opts, :strategy, :reserve_first),
      orders: %{},
      next_order: 1
    }

    {state, Fx.none()}
  end

  @impl true
  def update({:call, from, :buy}, s) when s.stock <= 0,
    do: {s, Fx.reply(from, {:error, :sold_out})}

  def update({:call, from, :buy}, s) do
    order = s.next_order
    s = %{s | next_order: order + 1, orders: Map.put(s.orders, order, :paying)}
    s = if s.strategy == :reserve_first, do: %{s | stock: s.stock - 1}, else: s
    charge = [method: :post, url: @payments_url, json: %{order: order}, retry: false]
    {s, Fx.http(charge, &{:charged, order, from, &1})}
  end

  def update({:charged, order, from, {:ok, %{status: 200}}}, s) do
    s = %{s | orders: Map.put(s.orders, order, :paid)}
    s = if s.strategy == :check_then_pay, do: %{s | stock: s.stock - 1}, else: s
    {s, Fx.reply(from, {:ok, order})}
  end

  def update({:charged, order, from, _failed}, s) do
    s = %{s | orders: Map.put(s.orders, order, :failed)}
    s = if s.strategy == :reserve_first, do: %{s | stock: s.stock + 1}, else: s
    {s, Fx.reply(from, {:error, :payment_failed})}
  end
end
