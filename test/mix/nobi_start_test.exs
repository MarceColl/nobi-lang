defmodule Mix.Tasks.Nobi.StartTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Nobi.Start

  test "boot asks Phoenix to serve before the app starts" do
    previous = Application.fetch_env(:phoenix, :serve_endpoints)
    Application.delete_env(:phoenix, :serve_endpoints)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:phoenix, :serve_endpoints, v)
        :error -> Application.delete_env(:phoenix, :serve_endpoints)
      end
    end)

    me = self()

    :ok =
      Start.boot(fn task, _args ->
        send(me, {task, Application.get_env(:phoenix, :serve_endpoints)})
      end)

    assert_received {"ecto.create", true}
    assert_received {"ecto.migrate", true}
    assert_received {"app.start", true}
  end
end
