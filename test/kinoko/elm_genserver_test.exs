defmodule Kinoko.ElmGenServerTest do
  use ExUnit.Case, async: true

  alias Kinoko.ElmGenServer
  alias Kinoko.ElmTestServer

  defp start(opts \\ []) do
    start_supervised!({ElmTestServer, opts}, id: make_ref())
  end

  describe "update/2 is pure" do
    test "returns state and effects as data without performing anything" do
      {state, []} = ElmTestServer.init([])
      from = {self(), make_ref()}

      assert {%{count: 1}, []} = ElmTestServer.update(:inc, state)

      assert {%{waiting: [^from]}, {:async, {:http, req}, to_msg}} =
               ElmTestServer.update({:call, from, :fetch}, state)

      assert req[:url] == "/"
      assert to_msg.({:ok, :resp}) == {:fetched, {:ok, :resp}}
      refute_received _
    end
  end

  describe "runtime" do
    test "casts and calls route through update" do
      pid = start(count: 5)
      ElmGenServer.cast(pid, :inc)
      assert ElmGenServer.call(pid, :count) == 6
    end

    test "dispatched msgs run in order before a deferred reply" do
      pid = start()
      assert ElmGenServer.call(pid, :inc_twice) == 2
    end

    test "http runs async and its result comes back as a msg" do
      test = self()

      plug = fn conn ->
        send(test, {:request_started, self()})
        receive do: (:release -> :ok)
        Req.Test.text(conn, "hello")
      end

      pid = start(req: [plug: plug])
      first = Task.async(fn -> ElmGenServer.call(pid, :fetch) end)
      assert_receive {:request_started, request}

      # The server keeps serving while the request is in flight.
      second = Task.async(fn -> ElmGenServer.call(pid, :fetch) end)
      ElmGenServer.cast(pid, :inc)
      assert ElmGenServer.call(pid, :count) == 1

      send(request, :release)
      assert Task.await(first) == {:ok, "hello"}
      assert Task.await(second) == {:ok, "hello"}
      refute_received {:request_started, _}
    end

    test "http failures come back as an error msg" do
      pid = start(req: [plug: &Req.Test.transport_error(&1, :econnrefused)])
      assert {:error, %Req.TransportError{reason: :econnrefused}} = ElmGenServer.call(pid, :fetch)

      pid = start(req: [plug: &Plug.Conn.send_resp(&1, 500, "")])
      assert ElmGenServer.call(pid, :fetch) == {:error, {:status, 500}}
    end

    test "after_ms routes the msg back later" do
      pid = start()
      assert ElmGenServer.call(pid, {:wake_in, 20}) == :awake
    end

    test "random and now deliver their values" do
      pid = start()
      assert ElmGenServer.call(pid, :roll) in 1..6
      assert %DateTime{time_zone: "Etc/UTC"} = ElmGenServer.call(pid, :now)
    end

    test "a crashing task becomes an error msg and the server survives" do
      pid = start()
      assert {:error, %RuntimeError{message: "boom"}} = ElmGenServer.call(pid, :crash_task)
      assert Process.alive?(pid)
    end

    test "stop effect terminates the server" do
      pid = start()
      ref = Process.monitor(pid)
      ElmGenServer.cast(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end
end
