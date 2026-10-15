defmodule Mix.Tasks.Kinoko.StartTest do
  use ExUnit.Case, async: true

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
end
