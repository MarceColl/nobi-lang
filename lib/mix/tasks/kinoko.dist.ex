defmodule Mix.Tasks.Kinoko.Dist do
  @shortdoc "Builds the single-binary kinoko for every target into dist/"

  @moduledoc """
  Builds the distributed `kinoko` binary with Burrito, one per target:

      mix kinoko.dist                          # every target
      mix kinoko.dist macos_arm64 linux_arm64  # some targets

  Steps:

    1. Checks the toolchain, reads the commit once, and fetches and verifies
       the pinned runtimes (below).
    2. `mix compile` and `mix assets.deploy`.
    3. For each target, the local release (`KINOKO_BUILD=local`) wrapped by
       Burrito (`KINOKO_DIST=1`, see `mix.exs`), written to
       `dist/kinoko-<os>-<arch>` with `dist/kinoko-<os>-<arch>.sha256`
       (`shasum -a 256` format).
    4. Always, even after a failure: removes the temp dirs Burrito left in the
       system temp dir, then the digested copies `phx.digest` wrote into
       `priv/static`, and rebuilds the dev assets.

  `dist/` and `burrito_out/` are git-ignored. The prod build runs in its own
  build path, `_build/dist`: it leaves `_build/dist/prod/rel/kinoko` behind
  (the Burrito-flavoured release, which boots Kinoko only through the
  binary's argv) and never touches the plain release in `_build/prod`.

  Targets (`mix.exs`, `burrito_targets/0`): `macos_arm64`, `macos_x86_64`,
  `linux_x86_64`, `linux_arm64`. The Linux binaries are static: Burrito's
  precompiled ERTS is built against musl, and the wrapper carries a musl
  runtime.

  ## Toolchain

    * **Zig 0.16.0, exactly.** Burrito 1.6.0 (`mix.lock`) compiles its
      wrapper with Zig and refuses any other version. Put a 0.16.0 `zig`
      first on `PATH` (https://ziglang.org/download/) if the system one
      differs.
    * `xz` on `PATH`.
    * Network on the first build, to fetch the pinned runtimes.

  ## Pinned runtimes (ERTS and musl)

  Burrito would download the precompiled ERTS from the BEAM Machine CDN
  (`beam-machine-universal.b-cdn.net`) without checking it. This task
  downloads it itself (with Req), checks it against the sha256 pinned in
  `@erts_pins` for the OTP and ERTS versions running the build, and hands
  Burrito the verified tarball as the target's `custom_erts`. The same goes
  for the Linux musl runtime (`@musl_pins`). A mismatch, or OTP/ERTS
  versions with no pin, stops the build (fail closed).

  Verified files are cached in `_build/dist/runtimes/` (never in Burrito's
  shared cache) and checked again on every use.

  The ERTS pins are trust on first use: BEAM Machine publishes no
  checksums (`<url>.sha256` is a 404). They were taken on 2026-10-17 from
  two independent downloads that agreed. The musl pins are
  Burrito 1.6.0's own: its musl files are named by their sha256, and the
  downloads matched those names.

  **Re-pinning** (a new OTP on the build machine): download the three
  tarballs the error names, `shasum -a 256` them, cross-check against a
  second download (or a published checksum, if one exists by then), and
  add an entry `{otp, erts}` to `@erts_pins`.

  ## The exqlite NIF (the only NIF)

    * The host target (`macos_arm64` on an Apple Silicon Mac) is no cross
      build: Burrito packs the NIF from the prod build, which is exqlite's
      own precompiled artifact (elixir_make's precompiler downloads it).
    * Every other target is a cross build: Burrito recompiles exqlite with
      `zig cc -target <arch>-macos` or `<arch>-linux`. Zig's default for
      `<arch>-linux` is a static, libc-free object, which loads under the
      musl ERTS.

  ## Version

  `kinoko version` prints the `mix.exs` version and the commit stamped at
  compile time (`Kinoko.Build`): `KINOKO_COMMIT` if set, else jj, else git.
  The task reads it once, before `assets.deploy`, and passes it to every
  target's build as `KINOKO_COMMIT`, so all binaries carry the same id. The
  release version is `<version>+<commit>`, so each build unpacks into its
  own Burrito directory (`kinoko_erts-<erts>_<version>+<commit>`); the
  directories of superseded builds are not removed automatically
  (`kinoko uninstall` names them).
  """

  use Mix.Task

  @zig_version "0.16.0"
  @dist_dir "dist"
  @runtimes_dir "_build/dist/runtimes"
  @cdn "https://beam-machine-universal.b-cdn.net"
  # BEAM Machine's cache-busting query, as Burrito 1.6.0 sends it.
  @query "?please-respect-my-bandwidth-costs=thank-you&openssl=3.5.1&musl=1.2.5"

  # {OTP, ERTS} => {os, cpu} => {path under the CDN, sha256}.
  @erts_pins %{
    {"28.1.1", "16.1.1"} => %{
      {:darwin, :aarch64} =>
        {"OTP-28.1.1/macos/universal/otp_28.1.1_macos_universal.tar.gz",
         "ac3a708d380218e14307f0667f67f888281acda27ba9e9f525c78757c6cd675a"},
      {:darwin, :x86_64} =>
        {"OTP-28.1.1/macos/universal/otp_28.1.1_macos_universal.tar.gz",
         "ac3a708d380218e14307f0667f67f888281acda27ba9e9f525c78757c6cd675a"},
      {:linux, :x86_64} =>
        {"OTP-28.1.1/linux/x86_64/any/otp_28.1.1_linux_any_x86_64.tar.gz",
         "0b29512d702fe19b5daa3fd98833a1fa7269103edb81fb8ac9d2c629960dadd2"},
      {:linux, :aarch64} =>
        {"OTP-28.1.1/linux/aarch64/any/otp_28.1.1_linux_any_aarch64.tar.gz",
         "bf07ae44f9b25bf23b020e647fe35df1d3c74842dfa8e541e9072c59d292cae2"}
    }
  }

  # cpu => sha256 of Burrito 1.6.0's musl runtime (musl 1.2.5).
  @musl_pins %{
    x86_64: "71c35316aff45bbfd243d8eb9bfc4a58b6eb97cee09514cd2030e145b68107fb",
    aarch64: "6b558025200a5ed1308e2ce2675217afec71b6c5a9d561e52262ca948d59905e"
  }

  @impl Mix.Task
  def run(args) do
    targets = targets(args)
    check_toolchain!()

    # One commit for every target, read before the build touches the tree.
    commit = Kinoko.Build.Commit.read()
    runtimes = Map.new(targets, &{&1, fetch_runtimes!(&1)})
    env = [{"KINOKO_COMMIT", commit}]
    burrito_tmp_before = burrito_tmp()

    try do
      # Compile first: esbuild resolves `phoenix-colocated` in the build path.
      shell!("mix", ["compile"], env: env)
      shell!("mix", ["assets.deploy"], env: env)
      Enum.each(targets, &build_target(&1, env ++ Map.fetch!(runtimes, &1)))
    after
      Enum.each(burrito_tmp() -- burrito_tmp_before, &File.rm_rf!/1)
      clean_digests()
    end
  end

  # Burrito leaves its work dir and the unpacked ERTS (about 115 MB) in the
  # system temp dir for every target it builds; this run's are removed.
  defp burrito_tmp do
    Path.wildcard(Path.join(System.tmp_dir!(), "{burrito_build,unpacked_erts}_*"))
  end

  defp targets(args) do
    all = Mix.Project.config()[:releases][:kinoko][:burrito][:targets] |> Keyword.keys()

    case args do
      [] ->
        all

      names ->
        Enum.map(names, fn name ->
          Enum.find(all, &(Atom.to_string(&1) == name)) ||
            Mix.raise("unknown target #{name}; targets: #{Enum.join(all, ", ")}")
        end)
    end
  end

  defp check_toolchain! do
    zig =
      System.find_executable("zig") ||
        Mix.raise("zig #{@zig_version} is not on PATH (Burrito needs exactly that version)")

    case System.cmd(zig, ["version"]) do
      {out, 0} ->
        if String.trim(out) != @zig_version,
          do: Mix.raise("zig on PATH is #{String.trim(out)}; Burrito needs #{@zig_version}")

      _ ->
        Mix.raise("could not run #{zig} version")
    end

    System.find_executable("xz") || Mix.raise("xz is not on PATH")
    :ok
  end

  # The verified runtime files for `target`, as the env of its build.
  defp fetch_runtimes!(target) do
    opts = Mix.Project.config()[:releases][:kinoko][:burrito][:targets][target]
    {os, cpu} = {opts[:os], opts[:cpu]}

    {path, sha} =
      case erts_pin(otp_version(), erts_version(), os, cpu) do
        {:ok, pin} -> pin
        {:error, message} -> Mix.raise(message)
      end

    erts = [{"KINOKO_DIST_ERTS", fetch_verified!(@cdn <> "/" <> path <> @query, sha)}]

    if os == :linux do
      musl_sha = Map.fetch!(@musl_pins, cpu)
      url = "#{@cdn}/musl/libc-musl-#{musl_sha}.so?please-respect-my-bandwidth-costs=thank-you"
      erts ++ [{"KINOKO_DIST_MUSL", fetch_verified!(url, musl_sha)}]
    else
      erts
    end
  end

  @doc """
  The pinned `{path, sha256}` of the ERTS tarball for `os`/`cpu` built from
  OTP `otp` (ERTS `erts`), or an error explaining how to re-pin.
  """
  @spec erts_pin(String.t(), String.t(), atom(), atom()) ::
          {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def erts_pin(otp, erts, os, cpu) do
    case @erts_pins[{otp, erts}][{os, cpu}] do
      {_, _} = pin ->
        {:ok, pin}

      nil ->
        {:error,
         """
         kinoko.dist: no pinned ERTS for OTP #{otp} (ERTS #{erts}), #{os}/#{cpu}.
         The build machine's OTP decides which ERTS Burrito packs. Either build
         with a pinned OTP (#{pinned_versions()}), or re-pin: download the
         BEAM Machine tarballs for OTP #{otp}
           #{@cdn}/OTP-#{otp}/macos/universal/otp_#{otp}_macos_universal.tar.gz
           #{@cdn}/OTP-#{otp}/linux/<x86_64|aarch64>/any/otp_#{otp}_linux_any_<arch>.tar.gz
         run `shasum -a 256` on each, cross-check against a second download,
         and add {"#{otp}", "#{erts}"} to @erts_pins in
         lib/mix/tasks/kinoko.dist.ex.
         """}
    end
  end

  defp pinned_versions do
    @erts_pins |> Map.keys() |> Enum.map_join(", ", fn {otp, erts} -> "#{otp}/#{erts}" end)
  end

  defp otp_version do
    [:code.root_dir(), "releases", :erlang.system_info(:otp_release), "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end

  defp erts_version, do: List.to_string(:erlang.system_info(:version))

  # The cached file for `url` when its sha256 is `sha`, else a fresh
  # download that must match. Fails closed.
  defp fetch_verified!(url, sha) do
    name = url |> URI.parse() |> Map.fetch!(:path) |> Path.basename()
    path = Path.expand(Path.join(@runtimes_dir, name))

    if File.exists?(path) and verified?(path, sha) do
      path
    else
      Mix.shell().info("==> kinoko.dist: downloading #{name}")
      {:ok, _} = Application.ensure_all_started(:req)
      File.mkdir_p!(@runtimes_dir)
      tmp = path <> ".part"

      case Req.get!(url, raw: true, into: File.stream!(tmp), retry: :transient) do
        %Req.Response{status: 200} -> :ok
        resp -> Mix.raise("kinoko.dist: GET #{url} answered #{resp.status}")
      end

      if verified?(tmp, sha) do
        File.rename!(tmp, path)
        path
      else
        File.rm!(tmp)
        Mix.raise("kinoko.dist: #{name} does not match its pinned sha256 #{sha}; refusing it")
      end
    end
  end

  @doc "Whether the file at `path` has the sha256 `sha` (lowercase hex)."
  @spec verified?(Path.t(), String.t()) :: boolean()
  def verified?(path, sha) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> Kernel.==(sha)
  end

  defp build_target(target, env) do
    Mix.shell().info("==> kinoko.dist: #{target}")

    shell!("mix", ["release", "kinoko", "--overwrite"],
      env: env ++ [{"BURRITO_TARGET", Atom.to_string(target)}]
    )

    name = binary_name(target)
    out = Path.join(@dist_dir, name)
    File.mkdir_p!(@dist_dir)
    File.cp!(Path.join("burrito_out", "kinoko_#{target}"), out)
    File.chmod!(out, 0o755)

    sha = :crypto.hash(:sha256, File.read!(out)) |> Base.encode16(case: :lower)
    File.write!(out <> ".sha256", "#{sha}  #{name}\n")
    Mix.shell().info("==> #{out} (#{File.stat!(out).size} bytes)")
  end

  @doc false
  @spec binary_name(atom()) :: String.t()
  def binary_name(target),
    do: "kinoko-" <> String.replace(Atom.to_string(target), "_", "-", global: false)

  # `phx.digest` writes digested copies (and .gz files) next to the sources
  # in priv/static (git-ignored, but they would ship in a plain prod build).
  defp clean_digests do
    shell!("mix", ["phx.digest.clean", "--all"])
    shell!("mix", ["assets.build"], env: [{"MIX_ENV", "dev"}])
  end

  # Release work runs in MIX_ENV=prod, the local build and the dist build
  # path (`_build/dist`), whatever the caller's environment says.
  defp shell!(cmd, args, opts \\ []) do
    env =
      [{"MIX_ENV", "prod"}, {"KINOKO_BUILD", "local"}, {"KINOKO_DIST", "1"}] ++
        Keyword.get(opts, :env, [])

    env = env |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))

    case System.cmd(cmd, args, env: env, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("#{cmd} #{Enum.join(args, " ")} failed (exit #{status})")
    end
  end
end
