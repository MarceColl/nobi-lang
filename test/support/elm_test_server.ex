defmodule Nobi.ElmTestServer do
  @moduledoc """
  A small `Nobi.ElmGenServer` used to exercise the runtime in tests:
  a counter, an HTTP fetch with deferred replies, timers and random.

  `init/1` takes keyword options; `:req` is merged into every HTTP request,
  so tests can pass `plug:` to stub the network.
  """

  use Nobi.ElmGenServer
  alias Nobi.Elm.Effect, as: Fx

  @impl true
  def init(opts) do
    state = %{
      count: Keyword.get(opts, :count, 0),
      req: Keyword.get(opts, :req, []),
      waiting: [],
      body: nil
    }

    {state, Fx.none()}
  end

  @impl true
  def update({:call, from, :count}, s), do: {s, Fx.reply(from, s.count)}

  def update(:inc, s), do: {%{s | count: s.count + 1}, Fx.none()}

  def update({:call, from, :inc_twice}, s),
    do: {s, [Fx.dispatch(:inc), Fx.dispatch(:inc), Fx.dispatch({:reply_count, from})]}

  def update({:reply_count, from}, s), do: {s, Fx.reply(from, s.count)}

  # Only the first caller triggers a request; everyone waiting gets the same answer.
  def update({:call, from, :fetch}, %{waiting: []} = s),
    do: {%{s | waiting: [from]}, Fx.http([url: "/", retry: false] ++ s.req, &{:fetched, &1})}

  def update({:call, from, :fetch}, s), do: {%{s | waiting: [from | s.waiting]}, Fx.none()}

  def update({:fetched, {:ok, %{status: 200, body: body}}}, s),
    do: {%{s | body: body, waiting: []}, reply_all(s.waiting, {:ok, body})}

  def update({:fetched, {:ok, %{status: status}}}, s),
    do: {%{s | waiting: []}, reply_all(s.waiting, {:error, {:status, status}})}

  def update({:fetched, {:error, e}}, s),
    do: {%{s | waiting: []}, reply_all(s.waiting, {:error, e})}

  def update({:call, from, {:wake_in, ms}}, s), do: {s, Fx.after_ms(ms, {:wake, from})}

  def update({:wake, from}, s), do: {s, Fx.reply(from, :awake)}

  def update({:call, from, :roll}, s), do: {s, Fx.random(1..6, &{:rolled, from, &1})}

  def update({:rolled, from, n}, s), do: {s, Fx.reply(from, n)}

  def update({:call, from, :now}, s), do: {s, Fx.now(&{:time, from, &1})}

  def update({:time, from, now}, s), do: {s, Fx.reply(from, now)}

  def update({:call, from, :crash_task}, s),
    do: {s, Fx.task(fn -> raise "boom" end, &{:crashed, from, &1})}

  def update({:crashed, from, result}, s), do: {s, Fx.reply(from, result)}

  def update(:stop, s), do: {s, Fx.stop(:normal)}

  defp reply_all(froms, value), do: Enum.map(froms, &Fx.reply(&1, value))
end
