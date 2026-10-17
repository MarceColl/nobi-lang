defmodule Kinoko.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :kinoko,
      version: @version,
      elixir: "~> 1.15",
      build_path: build_path(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Kinoko.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # KINOKO_BUILD (local | server) fixes the compile-time `:mcp_enabled` of a
  # prod build (config/prod.exs). Mix does not see an env var change, so each
  # build compiles into its own directory: `_build/prod` (local) and
  # `_build/server/prod` (server).
  #
  # `mix kinoko.dist` (KINOKO_DIST=1) builds in `_build/dist`, so its
  # Burrito-flavoured release never replaces the plain one in `_build/prod`.
  defp build_path do
    cond do
      Mix.env() == :prod and System.get_env("KINOKO_BUILD") == "server" -> "_build/server"
      Mix.env() == :prod and System.get_env("KINOKO_DIST") == "1" -> "_build/dist"
      true -> "_build"
    end
  end

  # `MIX_ENV=prod mix release` builds the local `kinoko` release: the console
  # and the MCP are compiled in (`:mcp_enabled`, set in config/prod.exs from
  # KINOKO_BUILD, default local). `bin/kinoko-cli` (rel/overlays) runs the
  # `kinoko` command, Kinoko.CLI.main/1.
  #
  # `mix kinoko.dist` sets KINOKO_DIST=1 to wrap that same release with
  # Burrito into one binary per target (see Mix.Tasks.Kinoko.Dist). The
  # binary boots the `start` script with `rel/burrito/vm.args.eex`, which
  # hands argv to Kinoko.CLI.main/1; `kinoko: :load` keeps the boot from
  # starting Kinoko itself, so `kinoko version` starts and creates nothing.
  # `rel/burrito` is its own templates dir, so `rel/overlays` (bin/kinoko-cli)
  # is not in the binary: the binary is the CLI.
  #
  # The dist release version is `<version>+<commit>` (KINOKO_COMMIT): Burrito
  # unpacks into a directory named after it and never unpacks again over an
  # existing one, so every build must have its own. `kinoko version` still
  # prints the mix.exs version and the commit (Kinoko.Build).
  #
  # The dist build only takes the ERTS the task verified: KINOKO_DIST_ERTS is
  # the pinned tarball for the target in BURRITO_TARGET (Burrito's
  # `custom_erts`), and Kinoko.Dist.PinnedRuntime refuses a build without it
  # and supplies the pinned musl runtime (KINOKO_DIST_MUSL) for Linux.
  defp releases do
    base = [
      include_executables_for: [:unix],
      steps: [:assemble],
      burrito: [targets: burrito_targets()]
    ]

    kinoko =
      if System.get_env("KINOKO_DIST") == "1",
        do:
          Keyword.merge(base,
            version: "#{@version}+#{System.get_env("KINOKO_COMMIT") || "unknown"}",
            steps: [:assemble, &Burrito.wrap/1],
            applications: [kinoko: :load],
            rel_templates_path: "rel/burrito",
            burrito: [
              targets: dist_targets(System.get_env("BURRITO_TARGET"), System.get_env()),
              extra_steps: [fetch: [pre: [Kinoko.Dist.PinnedRuntime]]]
            ]
          ),
        else: base

    [kinoko: kinoko]
  end

  defp dist_targets(target, env) do
    for {name, opts} <- burrito_targets() do
      if Atom.to_string(name) == target and env["KINOKO_DIST_ERTS"],
        do: {name, opts ++ [custom_erts: env["KINOKO_DIST_ERTS"]]},
        else: {name, opts}
    end
  end

  # The Burrito targets, `<os>_<arch>` (the binary is `kinoko-<os>-<arch>`).
  # Linux targets run Burrito's precompiled musl ERTS plus its musl runtime.
  defp burrito_targets do
    [
      macos_arm64: [os: :darwin, cpu: :aarch64],
      macos_x86_64: [os: :darwin, cpu: :x86_64],
      linux_x86_64: [os: :linux, cpu: :x86_64],
      linux_arm64: [os: :linux, cpu: :aarch64]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.17"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:burrito, "~> 1.6", runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind kinoko", "esbuild kinoko", "esbuild yabu"],
      "assets.deploy": [
        "tailwind kinoko --minify",
        "esbuild kinoko --minify",
        "esbuild yabu --minify",
        "phx.digest"
      ],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
