import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kinoko start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kinoko, KinokoWeb.Endpoint, server: true
end

if config_env() == :prod do
  # The run mode (Kinoko.Local): `local` (default) is the distributed
  # `kinoko` binary on one machine; `server` is a prod deploy.
  # Kinoko.Application refuses a build that does not fit the mode.
  env = System.get_env()
  mode = Kinoko.Local.mode(env)
  data_dir = Kinoko.Local.data_dir(mode, env)
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :kinoko, :mode, mode

  config :kinoko, Kinoko.Repo,
    database: Path.join(data_dir, "kinoko.db"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  config :kinoko, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  case mode do
    :local ->
      # Loopback only, http://localhost:<port>; the console and every
      # `<name>.localhost` app may open the LiveView socket. No secret here:
      # this file runs for every release command (`kinoko version` too), and
      # those must create nothing. Kinoko.Release.start/0 resolves it.
      config :kinoko, KinokoWeb.Endpoint,
        url: [host: "localhost", port: port, scheme: "http"],
        http: [ip: Kinoko.Local.bind_ip(:local), port: port],
        check_origin: Kinoko.Local.check_origin()

    :server ->
      # The secret key base is used to sign/encrypt cookies and other secrets.
      secret_key_base =
        System.get_env("SECRET_KEY_BASE") ||
          raise """
          environment variable SECRET_KEY_BASE is missing.
          You can generate one by calling: mix phx.gen.secret
          """

      host = System.get_env("PHX_HOST") || "example.com"

      config :kinoko, KinokoWeb.Endpoint,
        url: [host: host, port: 443, scheme: "https"],
        http: [
          # Enable IPv6 and bind on all interfaces.
          # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
          # for details about using IPv6 vs IPv4 and loopback vs public addresses.
          ip: Kinoko.Local.bind_ip(:server),
          port: port
        ],
        secret_key_base: secret_key_base
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kinoko, KinokoWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kinoko, KinokoWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :kinoko, Kinoko.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
