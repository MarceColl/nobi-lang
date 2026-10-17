defmodule Kinoko.Dist.PinnedRuntime do
  @moduledoc """
  A Burrito build step (fetch phase, before Burrito's own steps) of
  `mix kinoko.dist`. It runs inside `mix release` on the build machine,
  never in Kinoko.

    * It refuses a target whose ERTS is not the local tarball the task
      verified (`custom_erts` from `KINOKO_DIST_ERTS`, see `mix.exs`), so a
      dist build never falls back to Burrito's unverified download.
    * For Linux it installs the musl runtime from `KINOKO_DIST_MUSL`, which
      the task verified too. Burrito's own musl step only runs for its
      download-it-yourself ERTS, so with `custom_erts` this one does its job
      the same way: the runtime is embedded in the wrapper, which writes it
      to `/tmp/libc-musl-<sha256>.so` on first run.

  The context is Burrito's `%Burrito.Builder.Context{}`; it is used as a
  map so Kinoko does not depend on Burrito at compile time.
  """

  @doc "The step: returns the context, or raises when the runtime is not pinned."
  @spec execute(map()) :: map()
  def execute(%{target: target} = context) do
    case target.erts_source do
      {:local, path: path} when is_binary(path) -> :ok
      other -> raise "kinoko.dist: unverified ERTS #{inspect(other)}; build with mix kinoko.dist"
    end

    if target.os == :linux, do: install_musl(context), else: context
  end

  defp install_musl(context) do
    path =
      System.get_env("KINOKO_DIST_MUSL") ||
        raise "kinoko.dist: KINOKO_DIST_MUSL is not set; build with mix kinoko.dist"

    bytes = File.read!(path)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    File.write!(Path.join([context.self_dir, "src", "musl-runtime.so"]), bytes)

    %{
      context
      | extra_build_env:
          context.extra_build_env ++
            [{"__BURRITO_MUSL_RUNTIME_PATH", "/tmp/libc-musl-#{sha}.so"}]
    }
  end
end
