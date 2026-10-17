defmodule Mix.Tasks.Kinoko.Dist do
  @shortdoc "Builds the single-binary kinoko for every target into dist/"

  @moduledoc """
  Builds the distributed `kinoko` binary with Burrito, one per target:

      mix kinoko.dist                          # every target
      mix kinoko.dist macos_arm64 linux_arm64  # some targets

  It runs `mix assets.deploy`, then for each target the local release
  (`KINOKO_BUILD=local`) wrapped by Burrito (`KINOKO_DIST=1`, see `mix.exs`),
  and writes `dist/kinoko-<os>-<arch>` with a `dist/kinoko-<os>-<arch>.sha256`
  (`shasum -a 256` format). Last, it removes the digested copies that
  `phx.digest` wrote into `priv/static` and rebuilds the dev assets, so the
  working copy is as before, and removes the temp dirs Burrito left behind.
  `dist/` and `burrito_out/` are git-ignored.

  Targets (`mix.exs`, `burrito_targets/0`): `macos_arm64`, `macos_x86_64`,
  `linux_x86_64`, `linux_arm64`. The Linux binaries are static musl ones:
  Burrito ships its precompiled ERTS and a musl runtime with them.

  ## Toolchain

    * **Zig 0.16.0, exactly.** Burrito 1.6.0 (`mix.lock`) compiles its
      wrapper with Zig and refuses any other version. Put a 0.16.0 `zig`
      first on `PATH` (https://ziglang.org/download/) if the system one
      differs.
    * `xz` on `PATH`.
    * Network on the first build: Burrito downloads the precompiled ERTS
      for the OTP version that runs the build (and the musl runtime for
      Linux), then caches them.

  ## The exqlite NIF (the only NIF)

    * The host target (`macos_arm64` on an Apple Silicon Mac) is no cross
      build: Burrito packs the NIF from `_build/prod`, which is exqlite's
      own precompiled artifact (elixir_make's precompiler downloads it).
    * Every other target is a cross build: Burrito recompiles exqlite with
      `zig cc` for the target triple (`aarch64-linux-musl`, ...).

  ## Version

  `kinoko version` prints the `mix.exs` version and the commit stamped at
  compile time (`Kinoko.Build`): `KINOKO_COMMIT` if set, else jj, else git.
  The task reads it once, before `assets.deploy`, and passes it to every
  target's build as `KINOKO_COMMIT`, so all binaries carry the same id.
  """

  use Mix.Task

  @zig_version "0.16.0"
  @dist_dir "dist"

  @impl Mix.Task
  def run(args) do
    targets = targets(args)
    check_toolchain!()

    # One commit for every target, read before the build touches the tree.
    commit = Kinoko.Build.Commit.read()
    env = [{"KINOKO_COMMIT", commit}]

    shell!("mix", ["assets.deploy"], env: env)
    burrito_tmp_before = burrito_tmp()

    try do
      Enum.each(targets, &build_target(&1, env))
    after
      clean_digests()
      Enum.each(burrito_tmp() -- burrito_tmp_before, &File.rm_rf!/1)
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

  defp build_target(target, env) do
    Mix.shell().info("==> kinoko.dist: #{target}")

    shell!("mix", ["release", "kinoko", "--overwrite"],
      env: env ++ [{"KINOKO_DIST", "1"}, {"BURRITO_TARGET", Atom.to_string(target)}]
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
  # in priv/static; only priv/static/assets and the manifest are ignored.
  defp clean_digests do
    shell!("mix", ["phx.digest.clean", "--all"])
    shell!("mix", ["assets.build"], env: [{"MIX_ENV", "dev"}])
  end

  # Release work runs in MIX_ENV=prod and the local build, whatever the
  # caller's environment says.
  defp shell!(cmd, args, opts \\ []) do
    env = [{"MIX_ENV", "prod"}, {"KINOKO_BUILD", "local"}] ++ Keyword.get(opts, :env, [])
    env = env |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))

    case System.cmd(cmd, args, env: env, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("#{cmd} #{Enum.join(args, " ")} failed (exit #{status})")
    end
  end
end
