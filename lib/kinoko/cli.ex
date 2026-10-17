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

  (the release overlay `bin/kinoko-cli` wraps exactly that). The Burrito
  binary (`mix kinoko.dist`) evaluates the same call: its vm.args
  (`rel/burrito/vm.args.eex`) puts `-e Kinoko.CLI.main(System.argv()) --`
  before the binary's argv.

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
  def output(:uninstall), do: uninstall_text(uninstall_paths(System.get_env()))
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
  What `kinoko uninstall` prints, given the `binary`, the unpacked Burrito
  runtime `cache` and the `runtimes` pattern that matches every build's
  (both `nil` outside Burrito: nothing to list), and the `data` directory.
  """
  @spec uninstall_text(%{
          required(:binary) => String.t(),
          required(:cache) => String.t() | nil,
          optional(:runtimes) => String.t() | nil,
          required(:data) => String.t()
        }) :: String.t()
  def uninstall_text(%{binary: binary, cache: cache, data: data} = paths) do
    cache_line =
      if cache, do: "  #{shell_quote(cache)}    its unpacked runtime (Burrito cache)\n", else: ""

    runtimes_line =
      case paths[:runtimes] do
        nil -> ""
        runtimes -> "  #{shell_glob(runtimes)}    the runtimes of every kinoko build run here\n"
      end

    """
    To remove Kinoko, stop it and delete:

      #{shell_quote(binary)}    the kinoko binary
    #{cache_line}#{runtimes_line}  #{shell_quote(data)}    your data: the database, every app's data, the secret

    kinoko uninstall deletes nothing itself. Deleting the data directory
    deletes your work for good.
    """
  end

  # Single-quoted for a POSIX shell, so a copied path survives `rm -rf`
  # ("Application Support" has a space).
  defp shell_quote(path), do: "'" <> String.replace(path, "'", ~S('\'')) <> "'"

  # A pattern ending in `*`: the directory part quoted, the `*` left to glob.
  defp shell_glob(pattern) do
    if String.ends_with?(pattern, "*"),
      do: shell_quote(String.slice(pattern, 0..-2//1)) <> "*",
      else: shell_quote(pattern)
  end

  @doc """
  The paths `kinoko uninstall` lists, from the environment. Under Burrito
  (`__BURRITO` set) the wrapper sets `__BURRITO_BIN_PATH` to the binary and
  `RELEASE_ROOT` to its unpacked runtime: one directory per build,
  `<base>/.burrito/kinoko_erts-<erts>_<version>+<commit>`, where `<base>` is
  `$KINOKO_INSTALL_DIR`, else `~/Library/Application Support` (macOS) or
  `$XDG_DATA_HOME`, else `~/.local/share` (Linux). Earlier builds leave
  their own directories next to it, so `runtimes` is the pattern
  `<base>/.burrito/kinoko_erts-*`. The `.burrito` directory itself is
  shared with other Burrito apps, so only Kinoko's are listed. Outside
  Burrito the release's own script is the binary, and there is no cache.
  """
  @spec uninstall_paths(Kinoko.Local.env()) :: %{
          binary: String.t(),
          cache: String.t() | nil,
          runtimes: String.t() | nil,
          data: String.t()
        }
  def uninstall_paths(env) do
    {binary, cache} =
      if env["__BURRITO"] do
        {env["__BURRITO_BIN_PATH"] || "kinoko", env["RELEASE_ROOT"]}
      else
        root = env["RELEASE_ROOT"]
        {if(root, do: Path.join(root, "bin/kinoko"), else: "kinoko"), nil}
      end

    runtimes = if cache, do: Path.join(Path.dirname(cache), "kinoko_erts-*")

    %{
      binary: binary,
      cache: cache,
      runtimes: runtimes,
      data: Kinoko.Local.data_dir(:local, env)
    }
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
  (migrate, serve, `main` and `local`), then, under Burrito, the
  `Kinoko.ParentWatch` that stops Kinoko when the wrapper dies, then
  `announce/1`.
  """
  @spec start(keyword()) :: :ok
  def start(opts) do
    port = check_port!()

    case run_release_start() do
      :ok ->
        Kinoko.ParentWatch.maybe_start(System.get_env())
        announce(opts)

      failure ->
        IO.puts(:stderr, start_error_message(failure, port))
        if debug?(System.get_env()), do: IO.puts(:stderr, "\n" <> start_error_details(failure))
        System.halt(1)
    end
  end

  # A raise or exit in the start (an unwritable data dir, a short secret
  # file, a failed migration) is a failure like `{:error, reason}`, not a
  # crash with a stack trace.
  defp run_release_start do
    Kinoko.Release.start()
  rescue
    e -> {:exception, e, __STACKTRACE__}
  catch
    kind, reason -> {:caught, kind, reason, __STACKTRACE__}
  end

  @doc "Whether `KINOKO_DEBUG=1`: a failed start then also prints the full error."
  @spec debug?(Kinoko.Local.env()) :: boolean()
  def debug?(env), do: env["KINOKO_DEBUG"] == "1"

  @typedoc "How `Kinoko.Release.start/0` failed: its error, a raise, or a throw/exit."
  @type start_failure ::
          {:error, term()}
          | {:exception, Exception.t(), Exception.stacktrace()}
          | {:caught, :throw | :exit, term(), Exception.stacktrace()}

  @doc """
  The one line a failed start prints: the friendly "port in use" one when
  the bind failed (the port was taken after `check_port!/0`), else the
  first line of the error, with a pointer to `KINOKO_DEBUG=1`.
  """
  @spec start_error_message(start_failure(), :inet.port_number()) :: String.t()
  def start_error_message(failure, port) do
    if inspect(failure, limit: :infinity) =~ "eaddrinuse" do
      port_taken_message(port)
    else
      "kinoko: could not start: #{summary(failure)} (KINOKO_DEBUG=1 prints the full error)"
    end
  end

  defp summary({:exception, e, _}), do: one_line(Exception.message(e))
  defp summary({:caught, kind, reason, _}), do: one_line("#{kind} #{inspect(reason, limit: 8)}")
  defp summary({:error, reason}), do: one_line(inspect(reason, limit: 8, printable_limit: 120))

  defp one_line(text) do
    line = text |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")
    if String.length(line) > 240, do: String.slice(line, 0, 240) <> "...", else: line
  end

  @doc "The full error of a failed start, for `KINOKO_DEBUG=1`."
  @spec start_error_details(start_failure()) :: String.t()
  def start_error_details({:exception, e, stacktrace}),
    do: Exception.format(:error, e, stacktrace)

  def start_error_details({:caught, kind, reason, st}), do: Exception.format(kind, reason, st)
  def start_error_details({:error, reason}), do: inspect(reason, pretty: true, limit: :infinity)

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
