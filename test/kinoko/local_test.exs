defmodule Kinoko.LocalTest do
  # Writes files under a temp directory; no database.
  use ExUnit.Case, async: true

  import Bitwise

  alias Kinoko.Local

  @moduletag :tmp_dir

  describe "mode/1" do
    test "local unless KINOKO_MODE says server" do
      assert Local.mode(%{}) == :local
      assert Local.mode(%{"KINOKO_MODE" => "local"}) == :local
      assert Local.mode(%{"KINOKO_MODE" => "server"}) == :server
    end

    test "an unknown mode is refused" do
      assert_raise ArgumentError, ~r/KINOKO_MODE/, fn ->
        Local.mode(%{"KINOKO_MODE" => "cloud"})
      end
    end
  end

  describe "data_dir/2" do
    test "local mode defaults to ~/.kinoko", %{tmp_dir: home} do
      assert Local.data_dir(:local, %{"HOME" => home}) == Path.join(home, ".kinoko")
    end

    test "server mode defaults to /var/lib/kinoko", %{tmp_dir: home} do
      assert Local.data_dir(:server, %{"HOME" => home}) == "/var/lib/kinoko"
    end

    test "KINOKO_DATA wins in either mode", %{tmp_dir: home} do
      env = %{"HOME" => home, "KINOKO_DATA" => "/srv/k"}
      assert Local.data_dir(:local, env) == "/srv/k"
      assert Local.data_dir(:server, env) == "/srv/k"
    end
  end

  describe "secret_key_base/2" do
    test "generated once, mode 0600, and stable across calls", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "data")
      secret = Local.secret_key_base(dir, %{})

      path = Path.join(dir, "secret_key_base")
      assert File.exists?(path)
      assert (File.stat!(path).mode &&& 0o777) == 0o600
      assert byte_size(secret) >= 64

      assert Local.secret_key_base(dir, %{}) == secret
      assert String.trim(File.read!(path)) == secret
    end

    test "an existing secret file is put back to mode 0600", %{tmp_dir: tmp} do
      path = Path.join(tmp, "secret_key_base")
      File.write!(path, String.duplicate("s", 64) <> "\n")
      File.chmod!(path, 0o644)

      assert Local.secret_key_base(tmp, %{}) == String.duplicate("s", 64)
      assert (File.stat!(path).mode &&& 0o777) == 0o600
    end

    test "SECRET_KEY_BASE wins and writes nothing", %{tmp_dir: tmp} do
      assert Local.secret_key_base(tmp, %{"SECRET_KEY_BASE" => "from-env"}) == "from-env"
      refute File.exists?(Path.join(tmp, "secret_key_base"))
    end
  end

  test "bind address: loopback in local mode, every interface in server mode" do
    assert Local.bind_ip(:local) == {127, 0, 0, 1}
    # `::` (dual stack): 0.0.0.0 and every IPv6 address, as prod always bound.
    assert Local.bind_ip(:server) == {0, 0, 0, 0, 0, 0, 0, 0}
  end

  test "local check_origin allows localhost and its subdomains" do
    assert Local.check_origin() == ["//localhost", "//*.localhost"]
  end

  describe "check_build!/2" do
    test "server mode refuses a build that mounts the unauthenticated MCP" do
      assert_raise RuntimeError, ~r/KINOKO_BUILD=server/, fn ->
        Local.check_build!(:server, true)
      end

      assert Local.check_build!(:server, false) == :ok
    end

    test "local mode needs the MCP build" do
      assert_raise RuntimeError, ~r/mcp/i, fn -> Local.check_build!(:local, false) end
      assert Local.check_build!(:local, true) == :ok
    end
  end

  describe "open_browser?/1" do
    test "opens on macOS with a terminal" do
      assert Local.open_browser?(os: :darwin, env: %{}, tty?: true, no_open: false)
    end

    test "never with --no-open or without a terminal" do
      refute Local.open_browser?(os: :darwin, env: %{}, tty?: true, no_open: true)
      refute Local.open_browser?(os: :darwin, env: %{}, tty?: false, no_open: false)
    end

    test "on Linux only with a display" do
      refute Local.open_browser?(os: :linux, env: %{}, tty?: true, no_open: false)

      assert Local.open_browser?(
               os: :linux,
               env: %{"DISPLAY" => ":0"},
               tty?: true,
               no_open: false
             )

      assert Local.open_browser?(
               os: :linux,
               env: %{"WAYLAND_DISPLAY" => "wayland-0"},
               tty?: true,
               no_open: false
             )
    end

    test "never on an OS it has no opener for" do
      refute Local.open_browser?(
               os: :freebsd,
               env: %{"DISPLAY" => ":0"},
               tty?: true,
               no_open: false
             )
    end
  end

  test "opener: open on macOS, xdg-open on Linux" do
    assert Local.opener(:darwin) == "open"
    assert Local.opener(:linux) == "xdg-open"
    assert Local.opener(:freebsd) == nil
  end

  test "port_free?/2 sees a taken port" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    refute Local.port_free?({127, 0, 0, 1}, port)
    :gen_tcp.close(socket)
    assert Local.port_free?({127, 0, 0, 1}, port)
  end
end
