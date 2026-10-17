import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :nobi, Nobi.Repo,
  database: Path.expand("../.nobi/test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  # Sandbox transactions queue behind one another on the single writer.
  busy_timeout: 15_000,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :nobi, NobiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "yxe0z0MO35VQd1Ph6WCrqF7wwi3ICQBKQ2+/sJLrhKDyBsEbpNTP0R1NNMD9KC3R",
  server: false

# In test we don't send emails
config :nobi, Nobi.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# The SQL sandbox owns DB connections in test, so the boot-time
# Universe.Registry.ensure_main and Deployment.ensure_local tasks are skipped;
# tests call them explicitly.
config :nobi, :ensure_main_at_boot, false

# Mount the unauthenticated /mcp endpoint (off in a server build until it has auth).
config :nobi, mcp_enabled: true
