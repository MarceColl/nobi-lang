defmodule Nobi.UrlMonitorTest do
  use ExUnit.Case, async: true

  alias Nobi.UrlMonitor

  # The plug answers with whatever status the test last stored in the Agent.
  defp start_monitor(opts \\ []) do
    codes = start_supervised!({Agent, fn -> 200 end})
    plug = fn conn -> Plug.Conn.send_resp(conn, Agent.get(codes, & &1), "") end

    monitor =
      start_supervised!(
        {UrlMonitor, Keyword.merge([url: "http://monitored.test", req: [plug: plug]], opts)}
      )

    {monitor, codes}
  end

  test "checks on start and reports the result" do
    {monitor, _codes} = start_monitor()

    assert %{status: :up, code: 200, latency_ms: ms, checked_at: %DateTime{}} =
             UrlMonitor.check_now(monitor)

    assert is_integer(ms)
    assert UrlMonitor.status(monitor).status == :up
  end

  test "notifies subscribers on transitions only" do
    {monitor, codes} = start_monitor()
    UrlMonitor.check_now(monitor)
    :ok = UrlMonitor.subscribe(monitor)

    Agent.update(codes, fn _ -> 503 end)
    assert %{status: :down, code: 503} = UrlMonitor.check_now(monitor)
    assert_received {UrlMonitor, "http://monitored.test", :down}

    UrlMonitor.check_now(monitor)
    refute_received {UrlMonitor, _, _}

    Agent.update(codes, fn _ -> 200 end)
    UrlMonitor.check_now(monitor)
    assert_received {UrlMonitor, "http://monitored.test", :up}
  end

  test "transport errors count as down" do
    {monitor, _codes} =
      start_monitor(req: [plug: &Req.Test.transport_error(&1, :econnrefused)])

    assert %{status: :down, code: nil, error: error} = UrlMonitor.check_now(monitor)
    assert error =~ "connection refused"
  end

  test "keeps polling on its interval" do
    {monitor, codes} = start_monitor(interval: 10)
    :ok = UrlMonitor.subscribe(monitor)
    Agent.update(codes, fn _ -> 500 end)

    assert_receive {UrlMonitor, _, :down}, 500
  end
end
