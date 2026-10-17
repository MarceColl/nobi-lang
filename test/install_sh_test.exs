defmodule Kinoko.InstallShTest.FilePlug do
  @moduledoc false
  # Serves `root` (from conn.private) so the test needs no external server.
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, root: root) do
    path = Path.join(root, Path.basename(conn.request_path))

    if File.regular?(path) do
      send_file(conn, 200, path)
    else
      send_resp(conn, 404, "not found")
    end
  end
end

defmodule Kinoko.InstallShTest do
  # Runs the real install.sh against a local server over a fake dist/ of tiny
  # scripts. Touches no database, so it can be async.
  use ExUnit.Case, async: true

  import Bitwise

  alias Kinoko.InstallShTest.FilePlug

  @install Path.expand("../install.sh", __DIR__)
  @targets ~w(macos-arm64 macos-x86_64 linux-x86_64 linux-arm64)

  setup %{tmp_dir: tmp} do
    dist = Path.join(tmp, "dist")
    File.mkdir_p!(dist)

    for t <- @targets do
      body = "#!/bin/sh\necho fake-kinoko #{t}\n"
      File.write!(Path.join(dist, "kinoko-#{t}"), body)
      sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      File.write!(Path.join(dist, "kinoko-#{t}.sha256"), "#{sha}  kinoko-#{t}\n")
    end

    server =
      start_supervised!({Bandit, plug: {FilePlug, root: dist}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    %{dist: dist, base: "http://127.0.0.1:#{port}", dir: Path.join(tmp, "bin"), stubs: stubs(tmp)}
  end

  defp stubs(tmp) do
    path = Path.join(tmp, "stubs")
    File.mkdir_p!(path)
    path
  end

  defp stub(stubs, name, body) do
    file = Path.join(stubs, name)
    File.write!(file, "#!/bin/sh\n" <> body)
    File.chmod!(file, 0o755)
  end

  defp uname(stubs, os, arch) do
    stub(stubs, "uname", "case \"$1\" in -s) echo #{os};; -m) echo #{arch};; esac\n")
  end

  # Shells install.sh must work under; dash is skipped where it is absent.
  @shells Enum.filter(["sh", "dash"], &System.find_executable/1)

  defp install(env, stubs \\ nil, shell \\ "sh") do
    path = if stubs, do: stubs <> ":" <> System.get_env("PATH"), else: System.get_env("PATH")
    System.cmd(shell, [@install], env: [{"PATH", path} | env], stderr_to_stdout: true)
  end

  for shell <- @shells do
    @shell shell
    @tag :tmp_dir
    test "clean install under #{shell}: executable, runs, hints about PATH, next step", ctx do
      clean_install(ctx, @shell)
    end

    @tag :tmp_dir
    test "checksum mismatch under #{shell} is refused and nothing is installed", ctx do
      mismatch(ctx, @shell)
    end
  end

  defp clean_install(ctx, shell) do
    {out, 0} =
      install([{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}], nil, shell)

    bin = Path.join(ctx.dir, "kinoko")
    assert File.regular?(bin)
    assert (File.stat!(bin).mode &&& 0o777) == 0o755
    assert {"fake-kinoko " <> _, 0} = System.cmd(bin, [])
    assert out =~ "is not on your PATH"
    assert out =~ ~s(export PATH="#{ctx.dir}:$PATH")
    assert out =~ "Next: run  kinoko"
    assert Path.wildcard(Path.join(ctx.dir, ".kinoko.*"), match_dot: true) == []
  end

  defp mismatch(ctx, shell) do
    for t <- @targets, do: File.write!(Path.join(ctx.dist, "kinoko-#{t}"), "tampered\n")

    {out, status} =
      install([{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}], nil, shell)

    assert status != 0
    assert out =~ "checksum mismatch"
    refute File.exists?(Path.join(ctx.dir, "kinoko"))
    assert (File.ls(ctx.dir) |> elem(1)) in [[], :enoent]
  end

  @tag :tmp_dir
  test "no PATH hint when the install dir is already on PATH", ctx do
    path = ctx.dir <> ":" <> System.get_env("PATH")

    {out, 0} =
      System.cmd("sh", [@install],
        env: [{"PATH", path}, {"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}],
        stderr_to_stdout: true
      )

    refute out =~ "not on your PATH"
  end

  @tag :tmp_dir
  test "a failed download installs nothing", ctx do
    File.rm!(Path.join(ctx.dist, "kinoko-macos-arm64.sha256"))
    File.rm!(Path.join(ctx.dist, "kinoko-linux-x86_64.sha256"))
    File.rm!(Path.join(ctx.dist, "kinoko-linux-arm64.sha256"))
    File.rm!(Path.join(ctx.dist, "kinoko-macos-x86_64.sha256"))

    {out, status} = install([{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}])
    assert status != 0
    assert out =~ "could not download"
    refute File.exists?(Path.join(ctx.dir, "kinoko"))
  end

  @tag :tmp_dir
  test "an existing install is left alone when the new one fails verification", ctx do
    File.mkdir_p!(ctx.dir)
    File.write!(Path.join(ctx.dir, "kinoko"), "old")
    for t <- @targets, do: File.write!(Path.join(ctx.dist, "kinoko-#{t}"), "tampered\n")

    {_, status} = install([{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}])
    assert status != 0
    assert File.read!(Path.join(ctx.dir, "kinoko")) == "old"
  end

  @tag :tmp_dir
  test "unknown architecture and OS are refused", ctx do
    uname(ctx.stubs, "Linux", "riscv64")
    env = [{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}]

    {out, status} = install(env, ctx.stubs)
    assert status != 0
    assert out =~ "unsupported architecture: riscv64"
    refute File.exists?(Path.join(ctx.dir, "kinoko"))

    uname(ctx.stubs, "FreeBSD", "x86_64")
    {out, status} = install(env, ctx.stubs)
    assert status != 0
    assert out =~ "unsupported OS: FreeBSD"
  end

  @tag :tmp_dir
  test "uname values map to the four targets", ctx do
    env = [{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}]

    for {os, arch, target} <- [
          {"Darwin", "arm64", "macos-arm64"},
          {"Darwin", "x86_64", "macos-x86_64"},
          {"Linux", "aarch64", "linux-arm64"},
          {"Linux", "amd64", "linux-x86_64"}
        ] do
      uname(ctx.stubs, "#{os}", "#{arch}")
      stub(ctx.stubs, "sysctl", "echo 0\n")
      {_, 0} = install(env, ctx.stubs)
      assert {out, 0} = System.cmd(Path.join(ctx.dir, "kinoko"), [])
      assert out =~ "fake-kinoko #{target}"
    end
  end

  # A curl that records the URLs it is asked for and fails, so nothing is
  # downloaded and the URL formation is observable.
  defp url_log(ctx, env) do
    log = Path.join(ctx.stubs, "urls")
    uname(ctx.stubs, "Linux", "x86_64")
    stub(ctx.stubs, "curl", ~s(for a; do :; done; echo "$a" >> "#{log}"; exit 22\n))
    result = install([{"KINOKO_INSTALL_DIR", ctx.dir} | env], ctx.stubs)
    {result, if(File.exists?(log), do: File.read!(log), else: "")}
  end

  @tag :tmp_dir
  test "KINOKO_VERSION forms the release URL", ctx do
    {{_, status}, urls} =
      url_log(ctx, [{"KINOKO_REPO", "acme/kinoko"}, {"KINOKO_VERSION", "v1.2.3"}])

    assert status != 0
    assert urls =~ "https://github.com/acme/kinoko/releases/download/v1.2.3/kinoko-linux-x86_64"
  end

  @tag :tmp_dir
  test "the default version is latest/download", ctx do
    {{_, _}, urls} = url_log(ctx, [{"KINOKO_REPO", "acme/kinoko"}])
    assert urls =~ "https://github.com/acme/kinoko/releases/latest/download/kinoko-linux-x86_64"
  end

  @tag :tmp_dir
  test "KINOKO_BASE_URL overrides everything, trailing slash included", ctx do
    {{_, _}, urls} = url_log(ctx, [{"KINOKO_BASE_URL", "http://example.test/x/"}])
    assert urls =~ "http://example.test/x/kinoko-linux-x86_64"
  end

  @tag :tmp_dir
  test "the OWNER placeholder is refused before any download", ctx do
    {{out, status}, urls} = url_log(ctx, [])
    assert status != 0
    assert out =~ "no release repository configured"
    assert urls == ""
  end

  @tag :tmp_dir
  test "falls back to wget when curl is absent", ctx do
    # PATH holds only sh's basics plus a wget stub, no curl.
    bin = Path.join(ctx.stubs, "bin")
    File.mkdir_p!(bin)

    for tool <-
          ~w(uname mktemp rm mkdir cp mv chmod cut head cat dirname sha256sum shasum printf sh env) do
      if real = System.find_executable(tool), do: File.ln_s!(real, Path.join(bin, tool))
    end

    wget = Path.join(ctx.stubs, "wget.log")

    stub(
      bin,
      "wget",
      ~s(echo "$@" >> "#{wget}"; exec #{System.find_executable("curl")} -fsSL -o "$3" "$4"\n)
    )

    {out, status} =
      System.cmd("/bin/sh", [@install],
        env: [
          {"PATH", bin},
          {"KINOKO_BASE_URL", ctx.base},
          {"KINOKO_INSTALL_DIR", ctx.dir}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert File.read!(wget) =~ "-q -O"
    assert File.exists?(Path.join(ctx.dir, "kinoko"))
  end

  @tag :tmp_dir
  test "a failure after staging leaves no staged file and no temp dir", ctx do
    tmpdir = Path.join(ctx.stubs, "tmp")
    File.mkdir_p!(tmpdir)
    stub(ctx.stubs, "mv", "exit 1\n")

    {out, status} =
      install(
        [{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}, {"TMPDIR", tmpdir}],
        ctx.stubs
      )

    assert status != 0
    assert out =~ "cannot install"
    assert Path.wildcard(Path.join(ctx.dir, ".kinoko.*"), match_dot: true) == []
    refute File.exists?(Path.join(ctx.dir, "kinoko"))
    assert File.ls!(tmpdir) == []
  end

  @tag :tmp_dir
  test "a signal after staging exits 130 and leaves nothing behind", ctx do
    tmpdir = Path.join(ctx.stubs, "tmp")
    File.mkdir_p!(tmpdir)
    # mv signals its parent (the installer), then outlives the signal briefly.
    stub(ctx.stubs, "mv", "kill -TERM $PPID\nsleep 1\nexit 1\n")

    {_, status} =
      install(
        [{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}, {"TMPDIR", tmpdir}],
        ctx.stubs
      )

    assert status == 130
    assert Path.wildcard(Path.join(ctx.dir, ".kinoko.*"), match_dot: true) == []
    assert File.ls!(tmpdir) == []
  end

  @tag :tmp_dir
  test "a truncated script runs nothing and downloads nothing", ctx do
    log = Path.join(ctx.stubs, "urls")
    stub(ctx.stubs, "curl", ~s(echo "$@" >> "#{log}"; exit 22\n))
    lines = @install |> File.read!() |> String.split("\n") |> length()
    path = ctx.stubs <> ":" <> System.get_env("PATH")

    System.cmd(
      "sh",
      [
        "-c",
        "n=1; while [ \"$n\" -le \"$1\" ]; do head -n \"$n\" \"$2\" | sh; n=$((n + 1)); done",
        "x",
        "#{lines - 3}",
        @install
      ],
      env: [{"PATH", path}, {"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}],
      stderr_to_stdout: true
    )

    refute File.exists?(log)
    refute File.exists?(ctx.dir)
  end

  @tag :tmp_dir
  test "without KINOKO_INSTALL_DIR or HOME it refuses before downloading", ctx do
    log = Path.join(ctx.stubs, "urls")
    stub(ctx.stubs, "curl", ~s(echo "$@" >> "#{log}"; exit 22\n))

    {out, status} =
      System.cmd("sh", [@install],
        env: [
          {"PATH", ctx.stubs <> ":" <> System.get_env("PATH")},
          {"HOME", nil},
          {"KINOKO_BASE_URL", ctx.base}
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert out =~ "KINOKO_INSTALL_DIR"
    refute File.exists?(log)
  end

  @tag :tmp_dir
  test "https bases force https and TLS 1.2; http bases do not", ctx do
    log = Path.join(ctx.stubs, "args")
    uname(ctx.stubs, "Linux", "x86_64")
    stub(ctx.stubs, "curl", ~s(echo "$@" >> "#{log}"; exit 22\n))

    install(
      [{"KINOKO_BASE_URL", "https://example.test"}, {"KINOKO_INSTALL_DIR", ctx.dir}],
      ctx.stubs
    )

    assert File.read!(log) =~ "--proto =https --tlsv1.2"
    File.rm!(log)

    install(
      [{"KINOKO_BASE_URL", "http://example.test"}, {"KINOKO_INSTALL_DIR", ctx.dir}],
      ctx.stubs
    )

    refute File.read!(log) =~ "--proto"
  end

  @tag :tmp_dir
  test "an arm64 Mac under Rosetta gets the arm64 binary", ctx do
    uname(ctx.stubs, "Darwin", "x86_64")
    stub(ctx.stubs, "sysctl", "echo 1\n")
    {_, 0} = install([{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}], ctx.stubs)
    assert {out, 0} = System.cmd(Path.join(ctx.dir, "kinoko"), [])
    assert out =~ "macos-arm64"
  end

  @tag :tmp_dir
  test "trailing slash on the install dir is stripped for the PATH check", ctx do
    path = ctx.dir <> ":" <> System.get_env("PATH")

    {out, 0} =
      System.cmd("sh", [@install],
        env: [
          {"PATH", path},
          {"KINOKO_BASE_URL", ctx.base},
          {"KINOKO_INSTALL_DIR", ctx.dir <> "/"}
        ],
        stderr_to_stdout: true
      )

    refute out =~ "not on your PATH"
    assert File.exists?(Path.join(ctx.dir, "kinoko"))
  end

  @tag :tmp_dir
  test "the PATH hint is fish_add_path for fish and export otherwise", ctx do
    env = [{"KINOKO_BASE_URL", ctx.base}, {"KINOKO_INSTALL_DIR", ctx.dir}]
    {out, 0} = install([{"SHELL", "/usr/local/bin/fish"} | env])
    assert out =~ "fish_add_path #{ctx.dir}"
    refute out =~ "export PATH"
    {out, 0} = install([{"SHELL", "/bin/zsh"} | env])
    assert out =~ "export PATH"
  end
end
