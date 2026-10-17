defmodule Nobi.UrlMonitor do
  @moduledoc """
  Polls a URL and tracks whether it is up, built on `Nobi.ElmGenServer`.

      {:ok, pid} = Nobi.UrlMonitor.start_link(url: "https://example.com", interval: 30_000)
      Nobi.UrlMonitor.subscribe(pid)
      Nobi.UrlMonitor.check_now(pid)
      #=> %{status: :up, code: 200, latency_ms: 84, ...}

  A check is up when the response is 2xx/3xx, down on any other status or a
  transport error. Subscribers receive `{Nobi.UrlMonitor, url, :up | :down}`
  on every transition.

  Options:

    * `:url` (required)
    * `:interval` — ms between checks, default 30s
    * `:req` — extra `Req.request/1` options merged into every check
    * `:name` — process name
  """

  use Nobi.ElmGenServer
  alias Nobi.Elm.Effect, as: Fx

  @default_interval 30_000

  ## Client API

  def start_link(opts) do
    Nobi.ElmGenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :url)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Returns the result of the last completed check."
  def status(server), do: Nobi.ElmGenServer.call(server, :status)

  @doc "Runs a check now (or joins the one in flight) and returns its result."
  def check_now(server, timeout \\ 15_000),
    do: Nobi.ElmGenServer.call(server, :check_now, timeout)

  @doc "Sends `{Nobi.UrlMonitor, url, :up | :down}` to the caller on every transition."
  def subscribe(server), do: Nobi.ElmGenServer.call(server, :subscribe)

  ## ElmGenServer

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :url),
      interval: Keyword.get(opts, :interval, @default_interval),
      req: Keyword.get(opts, :req, []),
      status: :unknown,
      code: nil,
      error: nil,
      latency_ms: nil,
      checked_at: nil,
      # Each completed check schedules the next tick and bumps this, so a tick
      # scheduled before a check_now goes stale instead of doubling the polling.
      tick: 0,
      checking?: false,
      waiting: [],
      subscribers: []
    }

    {state, Fx.dispatch({:tick, 0})}
  end

  @impl true
  def update({:call, from, :status}, s), do: {s, Fx.reply(from, snapshot(s))}

  def update({:call, {pid, _} = from, :subscribe}, s),
    do: {%{s | subscribers: Enum.uniq([pid | s.subscribers])}, Fx.reply(from, :ok)}

  def update({:call, from, :check_now}, s), do: start_check(%{s | waiting: [from | s.waiting]})

  def update({:tick, tick}, %{tick: tick} = s), do: start_check(s)
  def update({:tick, _stale}, s), do: {s, Fx.none()}

  def update({:started, started_at}, s) do
    request = Keyword.merge([method: :get, url: s.url, retry: false], s.req)
    {s, Fx.http(request, &{:responded, started_at, &1})}
  end

  def update({:responded, started_at, result}, s),
    do: {s, Fx.now(&{:finished, started_at, result, &1})}

  def update({:finished, started_at, result, finished_at}, s) do
    {status, code, error} = classify(result)

    checked = %{
      s
      | status: status,
        code: code,
        error: error,
        latency_ms: DateTime.diff(finished_at, started_at, :millisecond),
        checked_at: finished_at,
        tick: s.tick + 1,
        checking?: false,
        waiting: []
    }

    # Notify before replying: a caller that is also a subscriber has the
    # transition in its mailbox by the time check_now returns.
    effects = [
      notify(s, checked),
      Enum.map(s.waiting, &Fx.reply(&1, snapshot(checked))),
      Fx.after_ms(s.interval, {:tick, checked.tick})
    ]

    {checked, effects}
  end

  defp start_check(%{checking?: true} = s), do: {s, Fx.none()}
  defp start_check(s), do: {%{s | checking?: true}, Fx.now(&{:started, &1})}

  defp classify({:ok, %{status: code}}) when code in 200..399, do: {:up, code, nil}
  defp classify({:ok, %{status: code}}), do: {:down, code, nil}
  defp classify({:error, exception}), do: {:down, nil, Exception.message(exception)}

  defp notify(%{status: same}, %{status: same}), do: Fx.none()

  defp notify(_before, after_check) do
    Enum.map(
      after_check.subscribers,
      &Fx.send_to(&1, {__MODULE__, after_check.url, after_check.status})
    )
  end

  defp snapshot(s), do: Map.take(s, [:url, :status, :code, :error, :latency_ms, :checked_at])
end
