defmodule Kinoko.CLITest do
  use ExUnit.Case, async: true

  alias Kinoko.CLI

  describe "parse/1" do
    test "no command, or start, starts and opens the browser" do
      assert CLI.parse([]) == {:start, open: true}
      assert CLI.parse(["start"]) == {:start, open: true}
    end

    test "--no-open is honoured with or without the start command" do
      assert CLI.parse(["--no-open"]) == {:start, open: false}
      assert CLI.parse(["start", "--no-open"]) == {:start, open: false}
    end

    test "mcp, version, uninstall and help" do
      assert CLI.parse(["mcp"]) == :mcp
      assert CLI.parse(["version"]) == :version
      assert CLI.parse(["--version"]) == :version
      assert CLI.parse(["uninstall"]) == :uninstall
      assert CLI.parse(["help"]) == :help
      assert CLI.parse(["--help"]) == :help
      assert CLI.parse(["-h"]) == :help
    end

    test "an unknown command or flag is an error" do
      assert CLI.parse(["deploy"]) == {:error, "unknown command: deploy"}
      assert CLI.parse(["start", "--bogus"]) == {:error, "unknown option: --bogus"}
      assert CLI.parse(["mcp", "extra"]) == {:error, "unexpected argument: extra"}
    end
  end

  describe "mcp_text/1" do
    test "names the claude command and a JSON config for other clients" do
      text = CLI.mcp_text(4123)

      assert text =~ "claude mcp add --transport http kinoko http://localhost:4123/mcp"

      [json] = Regex.run(~r/\{.*\}/s, text)

      assert Jason.decode!(json) == %{
               "mcpServers" => %{
                 "kinoko" => %{"type" => "http", "url" => "http://localhost:4123/mcp"}
               }
             }
    end
  end

  describe "banner/1" do
    test "names the app, console and MCP urls" do
      banner = CLI.banner("http://localhost:4000")
      assert banner =~ ~r{app\s+http://localhost:4000\n}
      assert banner =~ "http://localhost:4000/_"
      assert banner =~ "http://localhost:4000/mcp"
    end

    test "tells how to connect an agent" do
      assert CLI.banner("http://localhost:4000") =~ "connect an agent: kinoko mcp"
    end

    test "a trailing slash in the base url is ignored" do
      assert CLI.banner("http://localhost:4000/") == CLI.banner("http://localhost:4000")
    end
  end

  test "version_text/0 has the version and the build commit" do
    assert CLI.version_text() =~ ~r/^kinoko \d+\.\d+\.\d+ \(\S+\)$/
  end

  test "usage_text/0 lists every command" do
    usage = CLI.usage_text()
    for cmd <- ~w(start mcp version uninstall --no-open), do: assert(usage =~ cmd)
  end

  test "uninstall_text/1 lists what to delete and deletes nothing" do
    text =
      CLI.uninstall_text(%{
        binary: "/home/u/.local/bin/kinoko",
        cache: "/home/u/.local/share/.burrito",
        data: "/home/u/.kinoko"
      })

    assert text =~ "/home/u/.local/bin/kinoko"
    assert text =~ "/home/u/.local/share/.burrito"
    assert text =~ "/home/u/.kinoko"
  end

  test "port/1 reads PORT, default 4000" do
    assert CLI.port(%{}) == 4000
    assert CLI.port(%{"PORT" => "4123"}) == 4123
  end
end
