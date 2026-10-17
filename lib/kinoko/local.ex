defmodule Kinoko.Local do
  @moduledoc """
  The run mode of a prod release, and the pieces the local mode needs.

  A release runs in one of two modes, chosen by `KINOKO_MODE` at start:

    * `local` (the default): the distributed `kinoko` binary on one person's
      machine. It binds `127.0.0.1`, serves `http://localhost:<port>`, keeps
      its data in `~/.kinoko` and makes its own secret there.
    * `server`: the prod deploy as before. It binds every interface, serves
      https, keeps its data in `/var/lib/kinoko` and requires
      `SECRET_KEY_BASE`.

  `config/runtime.exs` calls these functions. Each takes the environment as
  a map, so tests never touch the real one.
  """

  import Bitwise

  @type mode :: :local | :server
  @type env :: %{optional(String.t()) => String.t()}

  @secret_file "secret_key_base"

  @doc "The mode named by `KINOKO_MODE`: `:local` unless it says `server`."
  @spec mode(env()) :: mode()
  def mode(env) do
    case Map.get(env, "KINOKO_MODE", "local") do
      "local" -> :local
      "server" -> :server
      other -> raise ArgumentError, "KINOKO_MODE must be local or server, got: #{inspect(other)}"
    end
  end

  @doc "The data directory: `KINOKO_DATA`, else `~/.kinoko` (local) or `/var/lib/kinoko` (server)."
  @spec data_dir(mode(), env()) :: String.t()
  def data_dir(mode, env) do
    case Map.get(env, "KINOKO_DATA") do
      dir when is_binary(dir) and dir != "" -> dir
      _ when mode == :server -> "/var/lib/kinoko"
      _ -> Path.join(Map.get(env, "HOME") || System.user_home!(), ".kinoko")
    end
  end

  @doc """
  The local secret key base: `SECRET_KEY_BASE` if set; otherwise the
  contents of `<data_dir>/secret_key_base`, made on first use from 64
  random bytes. The file is 0600 from birth and kept so; a file shorter
  than 64 bytes is refused (it names the file to delete).
  """
  @spec secret_key_base(String.t(), env()) :: String.t()
  def secret_key_base(data_dir, env) do
    case Map.get(env, "SECRET_KEY_BASE") do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> read_or_create_secret(Path.join(data_dir, @secret_file))
    end
  end

  defp read_or_create_secret(path) do
    case File.read(path) do
      {:ok, contents} -> read_secret(path, contents)
      {:error, :enoent} -> create_secret(path)
      {:error, reason} -> raise "cannot read #{path}: #{:file.format_error(reason)}"
    end
  end

  defp read_secret(path, contents) do
    secret = String.trim(contents)

    if byte_size(secret) < 64 do
      raise "the secret in #{path} is shorter than 64 bytes. " <>
              "Delete #{path} and Kinoko makes a new one on the next start " <>
              "(signed-in sessions end)."
    end

    :ok = keep_private(path)
    secret
  end

  # Written in full to a private temp file at 0600, then hard-linked into
  # place: the link is atomic and fails if the file exists, so concurrent
  # first runs agree (the losers read the winner's file) and the file never
  # exists partly written or with a looser mode.
  defp create_secret(path) do
    :ok = ensure_private_dir(Path.dirname(path))
    secret = Base.encode64(:crypto.strong_rand_bytes(64))
    tmp = path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))

    try do
      file =
        case File.open(tmp, [:write, :exclusive]) do
          {:ok, file} -> file
          {:error, reason} -> raise "cannot create #{tmp}: #{:file.format_error(reason)}"
        end

      :ok = File.chmod(tmp, 0o600)
      :ok = IO.binwrite(file, secret <> "\n")
      :ok = File.close(file)

      case File.ln(tmp, path) do
        :ok -> secret
        {:error, :eexist} -> read_or_create_secret(path)
        {:error, reason} -> raise "cannot create #{path}: #{:file.format_error(reason)}"
      end
    after
      File.rm(tmp)
    end
  end

  defp keep_private(path) do
    if (File.stat!(path).mode &&& 0o777) == 0o600, do: :ok, else: File.chmod(path, 0o600)
  end

  @doc """
  Creates `dir` (and its parents) when missing, the directory itself at
  0700. An existing directory keeps its mode.
  """
  @spec ensure_private_dir(String.t()) :: :ok
  def ensure_private_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end
  end

  @doc "The address to bind: loopback in local mode, every interface (`::`) in server mode."
  @spec bind_ip(mode()) :: :inet.ip_address()
  def bind_ip(:local), do: {127, 0, 0, 1}
  def bind_ip(:server), do: {0, 0, 0, 0, 0, 0, 0, 0}

  @doc "The endpoint's `check_origin` in local mode: the console (also as 127.0.0.1) and every `<name>.localhost` app."
  @spec check_origin() :: [String.t()]
  def check_origin, do: ["//localhost", "//*.localhost", "//127.0.0.1"]

  @doc """
  Refuses a release whose build does not fit its mode. `/mcp` has no auth,
  so a server must be built without it (`KINOKO_BUILD=server`); the local
  mode is the console and the MCP, so it needs them. `mcp_enabled` is the
  compile-time `:mcp_enabled` of the running build.
  """
  @spec check_build!(mode(), boolean()) :: :ok
  def check_build!(:server, true) do
    raise """
    KINOKO_MODE=server, but this release was built with the unauthenticated /mcp.
    Build the server release with KINOKO_BUILD=server MIX_ENV=prod mix release.
    """
  end

  def check_build!(:local, false) do
    raise """
    this release was built without the MCP and the console (KINOKO_BUILD=server).
    Run it with KINOKO_MODE=server, or build it without KINOKO_BUILD.
    """
  end

  def check_build!(_mode, _mcp_enabled), do: :ok

  @doc """
  Whether `port` is free for Kinoko on `ip`: the bind Bandit will do
  succeeds (with `reuseaddr`, as Bandit binds, so a previous run's
  TIME_WAIT sockets do not count), and nothing answers on `127.0.0.1:port`
  or `[::1]:port`. The connect probes catch a wildcard listener (`*:port`,
  `[::]:port`) or one on `::1`: on macOS the `reuseaddr` bind of
  `127.0.0.1` succeeds next to those, and a browser's `localhost` could
  then reach the other server.
  """
  @spec port_free?(:inet.ip_address(), :inet.port_number()) :: boolean()
  def port_free?(ip, port) do
    bind_free?(ip, port) and
      not answers?({127, 0, 0, 1}, port) and
      not answers?({0, 0, 0, 0, 0, 0, 0, 1}, port)
  end

  defp bind_free?(ip, port) do
    case :gen_tcp.listen(port, [ip: ip, reuseaddr: true] ++ family(ip)) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  # No IPv6 on the machine is an error too: nothing answers there.
  defp answers?(addr, port) do
    case :gen_tcp.connect(addr, port, [active: false] ++ family(addr), 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp family(ip) when tuple_size(ip) == 8, do: [:inet6]
  defp family(_ip), do: []

  @doc """
  Whether to open the browser. Options: `os` (`:darwin`, `:linux`, ...),
  `env`, `tty?` (stdout is a terminal) and `no_open`. Never with
  `--no-open`, without a terminal, on Linux without `DISPLAY` or
  `WAYLAND_DISPLAY`, or on an OS without a known opener.
  """
  @spec open_browser?(keyword()) :: boolean()
  def open_browser?(opts) do
    os = Keyword.fetch!(opts, :os)
    env = Keyword.fetch!(opts, :env)

    cond do
      Keyword.fetch!(opts, :no_open) -> false
      not Keyword.fetch!(opts, :tty?) -> false
      opener(os) == nil -> false
      os == :linux -> present?(env["DISPLAY"]) or present?(env["WAYLAND_DISPLAY"])
      true -> true
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  @doc "The command that opens a url on `os`, or `nil`."
  @spec opener(atom()) :: String.t() | nil
  def opener(:darwin), do: "open"
  def opener(:linux), do: "xdg-open"
  def opener(_os), do: nil

  @doc """
  Opens `url` in the browser when `open_browser?/1` allows it on this
  machine. Any failure is ignored.
  """
  @spec open_browser(String.t(), keyword()) :: :ok
  def open_browser(url, opts \\ []) do
    os = os()

    allowed? =
      open_browser?(
        os: os,
        env: System.get_env(),
        tty?: stdout_tty?(),
        no_open: Keyword.get(opts, :no_open, false)
      )

    if allowed?, do: run_opener(opener(os), url)
    :ok
  end

  defp run_opener(cmd, url) do
    with path when is_binary(path) <- System.find_executable(cmd) do
      System.cmd(path, [url], stderr_to_stdout: true)
    end
  rescue
    _ -> :ok
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, :linux} -> :linux
      {_, other} -> other
    end
  end

  defp stdout_tty?,
    do: tty?(System.get_env(), Keyword.get(:io.getopts(:standard_io), :stdout, false))

  @doc """
  Whether stdout is a terminal, given the env and what the VM sees
  (`io_tty?`). Burrito's wrapper pipes the VM's stdout through itself, so
  the VM never sees a terminal; the wrapper reports its own stdout in
  `_IS_TTY` (`1` or `0`), and that wins when `__BURRITO` is set.
  """
  @spec tty?(env(), boolean()) :: boolean()
  def tty?(env, io_tty?) do
    if env["__BURRITO"], do: env["_IS_TTY"] == "1", else: io_tty? == true
  end
end
