# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :nobi,
  ecto_repos: [Nobi.Repo],
  generators: [timestamp_type: :utc_datetime]

# One SQLite file per node; the path is set per environment (prod: runtime.exs).
# WAL lets readers run beside the single writer; busy_timeout makes a
# contended writer wait instead of failing with "database is locked".
# Transactions begin IMMEDIATE, taking the write lock up front: a deferred
# transaction that reads and then writes cannot wait for the lock.
config :nobi, Nobi.Repo,
  journal_mode: :wal,
  busy_timeout: 5000,
  foreign_keys: :on,
  default_transaction_mode: :immediate

# Each deployment's own SQLite file (Nobi.Data): a separate repo, never in
# ecto_repos, started per file as a dynamic instance (the database path is
# given at start). The same pragmas as Nobi.Repo, for the same reasons.
config :nobi, Nobi.Data.Repo,
  journal_mode: :wal,
  busy_timeout: 5000,
  foreign_keys: :on,
  default_transaction_mode: :immediate,
  pool_size: 2

# Configures the endpoint
config :nobi, NobiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: NobiWeb.ErrorHTML, json: NobiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Nobi.PubSub,
  live_view: [signing_salt: "UQhZyz3o"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :nobi, Nobi.Mailer, adapter: Swoosh.Adapters.Local

# WASM call limits (`Nobi.Wasm`), read at call time. Fuel is the hard CPU
# bound: about 1e9 per second of a tight loop on the reference box, so the
# default runs out at about the deadline. `concurrency` defaults to
# min(schedulers, 4).
config :nobi, Nobi.Wasm,
  fuel: 30_000_000_000,
  deadline_ms: 30_000,
  memory_bytes: 256 * 1024 * 1024,
  queue: 16,
  max_input: 8 * 1024 * 1024,
  max_output: 8 * 1024 * 1024,
  max_module: 32 * 1024 * 1024

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  nobi: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # Served Nobi apps only: the vendored Tailwind browser build.
  apps: [
    args: ~w(js/nobi.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  nobi: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ],
  # The static homepage (mix site.build): site/src -> site/dist. The build
  # passes --output (the dist directory it writes).
  site: [
    args: ~w(
      --input=site/src/site.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
