defmodule Nobi.Dist.PinnedRuntime do
  @moduledoc """
  A Burrito build step (fetch phase, before Burrito's own steps) of
  `mix nobi.dist`. It runs inside `mix release` on the build machine,
  never in Nobi.

    * It refuses a target whose ERTS is not the local tarball the task
      verified (`custom_erts` from `NOBI_DIST_ERTS`, see `mix.exs`), so a
      dist build never falls back to Burrito's unverified download.
    * For Linux it installs the musl runtime from `NOBI_DIST_MUSL`, which
      the task verified too. Burrito's own musl step only runs for its
      download-it-yourself ERTS, so with `custom_erts` this one does its job
      the same way: the runtime is embedded in the wrapper, which writes it
      to `/tmp/libc-musl-<sha256>.so` on first run and verifies it before
      every use (Nobi's Burrito patch, see `mix help nobi.dist`).

  The context is Burrito's `%Burrito.Builder.Context{}`; it is used as a
  map so Nobi does not depend on Burrito at compile time.
  """

  @doc "The step: returns the context, or raises when the runtime is not pinned."
  @spec execute(map()) :: map()
  def execute(%{target: target} = context) do
    case target.erts_source do
      {:local, path: path} when is_binary(path) -> :ok
      other -> raise "nobi.dist: unverified ERTS #{inspect(other)}; build with mix nobi.dist"
    end

    if target.os == :linux, do: install_musl(context), else: context
  end

  defp install_musl(context) do
    path =
      System.get_env("NOBI_DIST_MUSL") ||
        raise "nobi.dist: NOBI_DIST_MUSL is not set; build with mix nobi.dist"

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
