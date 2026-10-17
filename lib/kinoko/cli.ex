defmodule Kinoko.CLI do
  @moduledoc """
  The `kinoko` command, the entry point of the distributed release.

      kinoko [start] [--no-open]   migrate, start, open the console
      kinoko mcp                   how to connect an agent to the MCP
      kinoko version               version and build commit
      kinoko uninstall             what to delete (deletes nothing)

  `main/1` is the one entry: it takes argv and never returns. Without
  Burrito, a release runs it with

      bin/kinoko eval 'Kinoko.CLI.main(System.argv())' start --no-open

  (the release overlay `bin/kinoko-cli` wraps exactly that).

  `start/1` is `check_port!/0`, `Kinoko.Release.start/0` and `announce/1`,
  so a caller that boots the application another way can reuse the parts.
  """

  @usage """
  usage: kinoko [command] [--no-open]

    start        create and migrate the database, start Kinoko, open the
                 console (the default command)
      --no-open  do not open the browser
    mcp          print how to connect an agent to Kinoko's MCP
    version      print the version and the build commit
    uninstall    print what to delete to remove Kinoko (deletes nothing)
    help         print this help
  """

  @type command ::
          {:start, [open: boolean()]}
          | :mcp
          | :version
          | :uninstall
          | :help
          | {:error, String.t()}

  @doc "Runs the command in `argv`, then halts the VM (a `start` serves until stopped)."
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case parse(argv) do
      {:start, opts} ->
        start(opts)
        Process.sleep(:infinity)

      {:error, message} ->
        IO.puts(:stderr, "kinoko: #{message}\n\n" <> @usage)
        System.halt(64)

      command ->
        IO.write(output(command))
        System.halt(0)
    end
  end

  @doc "Parses argv into a command. No command is `start`."
  @spec parse([String.t()]) :: command()
  def parse(argv) do
    case argv do
      [] -> start_opts([])
      ["--" <> _ = flag | _] when flag not in ["--help", "--version"] -> start_opts(argv)
      ["start" | rest] -> start_opts(rest)
      ["mcp" | rest] -> no_args(:mcp, rest)
      ["version" | rest] -> no_args(:version, rest)
      ["--version" | rest] -> no_args(:version, rest)
      ["uninstall" | rest] -> no_args(:uninstall, rest)
      [help | rest] when help in ["help", "--help", "-h"] -> no_args(:help, rest)
      [other | _] -> {:error, "unknown command: #{other}"}
    end
  end

  defp start_opts(args) do
    case OptionParser.parse(args, strict: [open: :boolean]) do
      {opts, [], []} -> {:start, open: Keyword.get(opts, :open, true)}
      {_, [arg | _], []} -> {:error, "unexpected argument: #{arg}"}
      {_, _, [{flag, _} | _]} -> {:error, "unknown option: #{flag}"}
    end
  end

  defp no_args(command, []), do: command
  defp no_args(_command, [arg | _]), do: {:error, "unexpected argument: #{arg}"}

  @doc "What a non-start command prints. Pure: it creates nothing."
  @spec output(:mcp | :version | :uninstall | :help) :: String.t()
  def output(:mcp), do: mcp_text(port(System.get_env()))
  def output(:version), do: version_text() <> "\n"
  def output(:uninstall), do: uninstall_text(uninstall_paths())
  def output(:help), do: @usage

  @doc "The usage text."
  @spec usage_text() :: String.t()
  def usage_text, do: @usage

  @doc "The port the server listens on: `PORT`, default 4000."
  @spec port(Kinoko.Local.env()) :: :inet.port_number()
  def port(env), do: String.to_integer(Map.get(env, "PORT") || "4000")

  @doc "What `kinoko mcp` prints for a server on `port`."
  @spec mcp_text(:inet.port_number()) :: String.t()
  def mcp_text(port) do
    url = "http://localhost:#{port}/mcp"

    json =
      Jason.encode!(%{"mcpServers" => %{"kinoko" => %{"type" => "http", "url" => url}}},
        pretty: true
      )

    """
    Connect an agent to Kinoko's MCP (Kinoko must be running: kinoko start).

    Claude Code:

      claude mcp add --transport http kinoko #{url}

    Other clients (JSON config):

    #{json}
    """
  end

  @doc "What `kinoko version` prints: the version and the build commit."
  @spec version_text() :: String.t()
  def version_text, do: "kinoko #{Kinoko.Build.version()} (#{Kinoko.Build.commit()})"

  @doc """
  What `kinoko uninstall` prints, given the `binary`, the Burrito `cache`
  and the `data` directory.
  """
  @spec uninstall_text(%{binary: String.t(), cache: String.t(), data: String.t()}) :: String.t()
  def uninstall_text(%{binary: binary, cache: cache, data: data}) do
    """
    To remove Kinoko, stop it and delete:

      #{binary}    the kinoko binary
      #{cache}    its unpacked runtime (Burrito cache)
      #{data}    your data: the database, every app's data, the secret

    kinoko uninstall deletes nothing itself. Deleting the data directory
    deletes your work for good.
    """
  end

  # The binary is Burrito's when wrapped (`__BURRITO_BIN_PATH`), else the
  # release's own script. The Burrito cache is its default install root.
  defp uninstall_paths do
    env = System.get_env()

    binary =
      env["__BURRITO_BIN_PATH"] ||
        if(env["RELEASE_ROOT"], do: Path.join(env["RELEASE_ROOT"], "bin/kinoko"), else: "kinoko")

    cache =
      case :os.type() do
        {:unix, :darwin} -> Path.expand("~/Library/Application Support/.burrito")
        _ -> Path.join(env["XDG_DATA_HOME"] || Path.expand("~/.local/share"), ".burrito")
      end

    %{binary: binary, cache: cache, data: Kinoko.Local.data_dir(:local, env)}
  end

  @doc "The start-up banner for the endpoint at `base_url`."
  @spec banner(String.t()) :: String.t()
  def banner(base_url) do
    base = String.trim_trailing(base_url, "/")

    """

      Kinoko is running

        app       #{base}
        console   #{base}/_
        MCP       #{base}/mcp

      connect an agent: kinoko mcp
    """
  end

  @doc """
  `kinoko start`: refuses a taken port, then `Kinoko.Release.start/0`
  (migrate, serve, `main` and `local`), then `announce/1`.
  """
  @spec start(keyword()) :: :ok
  def start(opts) do
    port = check_port!()

    case Kinoko.Release.start() do
      :ok ->
        announce(opts)

      {:error, reason} ->
        IO.puts(:stderr, start_error_message(reason, port))
        System.halt(1)
    end
  end

  @doc """
  The message for a failed start: the friendly "port in use" one when the
  bind failed (the port was taken after `check_port!/0`), else the reason.
  """
  @spec start_error_message(term(), :inet.port_number()) :: String.t()
  def start_error_message(reason, port) do
    if inspect(reason, limit: :infinity) =~ "eaddrinuse",
      do: port_taken_message(port),
      else: "kinoko: could not start: #{inspect(reason)}"
  end

  defp port_taken_message(port),
    do: "kinoko: port #{port} is in use. Stop what uses it, or set PORT."

  @doc """
  Exits 1 when the endpoint's address is taken, else returns the port.
  Kinoko never tries another port by itself.
  """
  @spec check_port!() :: :inet.port_number()
  def check_port! do
    Application.load(:kinoko)
    http = Application.get_env(:kinoko, KinokoWeb.Endpoint, [])[:http] || []
    port = Keyword.get(http, :port, 4000)

    if Kinoko.Local.port_free?(Keyword.get(http, :ip, {127, 0, 0, 1}), port) do
      port
    else
      IO.puts(:stderr, port_taken_message(port))
      System.halt(1)
    end
  end

  @doc "Prints the banner and opens the console, unless `open: false`."
  @spec announce(keyword()) :: :ok
  def announce(opts) do
    base = KinokoWeb.Endpoint.url()
    IO.puts(banner(base))
    Kinoko.Local.open_browser(String.trim_trailing(base, "/") <> "/_", no_open: !opts[:open])
  end
end
