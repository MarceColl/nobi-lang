# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :kinoko,
  ecto_repos: [Kinoko.Repo],
  generators: [timestamp_type: :utc_datetime]

# One SQLite file per node; the path is set per environment (prod: runtime.exs).
# WAL lets readers run beside the single writer; busy_timeout makes a
# contended writer wait instead of failing with "database is locked".
# Transactions begin IMMEDIATE, taking the write lock up front: a deferred
# transaction that reads and then writes cannot wait for the lock.
config :kinoko, Kinoko.Repo,
  journal_mode: :wal,
  busy_timeout: 5000,
  foreign_keys: :on,
  default_transaction_mode: :immediate

# Each deployment's own SQLite file (Kinoko.Data): a separate repo, never in
# ecto_repos, started per file as a dynamic instance (the database path is
# given at start). The same pragmas as Kinoko.Repo, for the same reasons.
config :kinoko, Kinoko.Data.Repo,
  journal_mode: :wal,
  busy_timeout: 5000,
  foreign_keys: :on,
  default_transaction_mode: :immediate,
  pool_size: 2

# Configures the endpoint
config :kinoko, KinokoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KinokoWeb.ErrorHTML, json: KinokoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Kinoko.PubSub,
  live_view: [signing_salt: "UQhZyz3o"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :kinoko, Kinoko.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kinoko: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  kinoko: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
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
