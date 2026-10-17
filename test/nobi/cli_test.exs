defmodule Nobi.CLITest do
  use ExUnit.Case, async: true

  alias Nobi.CLI

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

      assert text =~ "claude mcp add --transport http nobi http://localhost:4123/mcp"

      [json] = Regex.run(~r/\{.*\}/s, text)

      assert Jason.decode!(json) == %{
               "mcpServers" => %{
                 "nobi" => %{"type" => "http", "url" => "http://localhost:4123/mcp"}
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
      assert CLI.banner("http://localhost:4000") =~ "connect an agent: nobi mcp"
    end

    test "a trailing slash in the base url is ignored" do
      assert CLI.banner("http://localhost:4000/") == CLI.banner("http://localhost:4000")
    end
  end

  test "version_text/0 has the version and the build commit" do
    assert CLI.version_text() =~ ~r/^nobi \d+\.\d+\.\d+ \(\S+\)$/
  end

  test "usage_text/0 lists every command" do
    usage = CLI.usage_text()
    for cmd <- ~w(start mcp version uninstall --no-open), do: assert(usage =~ cmd)
  end

  test "uninstall_text/1 lists what to delete and deletes nothing" do
    text =
      CLI.uninstall_text(%{
        binary: "/home/u/.local/bin/nobi",
        cache: "/home/u/.local/share/.burrito",
        data: "/home/u/.nobi"
      })

    assert text =~ "/home/u/.local/bin/nobi"
    assert text =~ "/home/u/.local/share/.burrito"
    assert text =~ "/home/u/.nobi"
  end

  test "uninstall_text/1 names every build's runtime under Burrito" do
    text =
      CLI.uninstall_text(%{
        binary: "/b/nobi",
        cache: "/h/.burrito/nobi_erts-16.1.1_0.1.0+abc",
        runtimes: "/h/.burrito/nobi_erts-*",
        data: "/d"
      })

    assert text =~ "/h/.burrito/nobi_erts-16.1.1_0.1.0+abc"
    assert text =~ "'/h/.burrito/nobi_erts-'*"
  end

  test "uninstall_text/1 single-quotes every path, so a copied one survives rm -rf" do
    text =
      CLI.uninstall_text(%{
        binary: "/Users/u/bin/nobi",
        cache: "/Users/u/Library/Application Support/.burrito/nobi_erts-16.1.1_0.1.0+abc",
        runtimes: "/Users/u/Library/Application Support/.burrito/nobi_erts-*",
        data: "/Users/o'brien/.nobi"
      })

    assert text =~ "'/Users/u/bin/nobi'"
    assert text =~ "'/Users/u/Library/Application Support/.burrito/nobi_erts-16.1.1_0.1.0+abc'"
    # The glob stays outside the quotes so the shell still expands it.
    assert text =~ "'/Users/u/Library/Application Support/.burrito/nobi_erts-'*"
    assert text =~ ~S('/Users/o'\''brien/.nobi')

    # What a shell makes of the printed data path is the path itself.
    [quoted] = Regex.run(~r/^  ('.*')    your data/m, text, capture: :all_but_first)
    assert {"/Users/o'brien/.nobi\n", 0} = System.cmd("sh", ["-c", "printf '%s\\n' " <> quoted])
  end

  test "uninstall_text/1 without a Burrito cache lists no cache line" do
    text = CLI.uninstall_text(%{binary: "/r/bin/nobi", cache: nil, data: "/d"})
    assert text =~ "/r/bin/nobi"
    refute text =~ "Burrito"
  end

  describe "uninstall_paths/1" do
    test "under Burrito: the wrapper's binary and its unpacked runtime" do
      env = %{
        "__BURRITO" => "1",
        "__BURRITO_BIN_PATH" => "/home/u/.local/bin/nobi",
        "RELEASE_ROOT" => "/home/u/.local/share/.burrito/nobi_erts-16.1_0.1.0",
        "NOBI_DATA" => "/home/u/k"
      }

      assert CLI.uninstall_paths(env) == %{
               binary: "/home/u/.local/bin/nobi",
               cache: "/home/u/.local/share/.burrito/nobi_erts-16.1_0.1.0",
               runtimes: "/home/u/.local/share/.burrito/nobi_erts-*",
               data: "/home/u/k"
             }
    end

    test "a plain release: its own script, no cache" do
      env = %{"RELEASE_ROOT" => "/opt/nobi", "NOBI_DATA" => "/home/u/k"}

      assert CLI.uninstall_paths(env) == %{
               binary: "/opt/nobi/bin/nobi",
               cache: nil,
               runtimes: nil,
               data: "/home/u/k"
             }
    end
  end

  test "port/1 reads PORT, default 4000" do
    assert CLI.port(%{}) == 4000
    assert CLI.port(%{"PORT" => "4123"}) == 4123
  end
end
