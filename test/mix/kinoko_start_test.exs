defmodule Mix.Tasks.Kinoko.StartTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kinoko.Start

  test "the banner names the app, console and MCP urls" do
    banner = Start.banner("http://localhost:4000")
    assert banner =~ "http://localhost:4000\n" or banner =~ "http://localhost:4000 "
    assert banner =~ "http://localhost:4000/_"
    assert banner =~ "http://localhost:4000/mcp"
  end

  test "a trailing slash in the base url is ignored" do
    assert Start.banner("http://localhost:4000/") == Start.banner("http://localhost:4000")
  end

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
