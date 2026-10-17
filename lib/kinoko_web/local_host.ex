defmodule KinokoWeb.LocalHost do
  @moduledoc """
  In local mode (`config :kinoko, :mode, :local`, see `Kinoko.Local`),
  refuses every request whose `Host` is not a loopback name: `localhost`,
  `127.0.0.1`, `[::1]` or `<name>.localhost`, on any port. The refusal is a
  403 with a short plain-text body. In any other mode, or with no mode set
  (dev, test), it lets everything through.

  It closes two holes the `Origin` checks leave open:

    * **DNS rebinding.** A page on `evil.example` that rebinds its name to
      `127.0.0.1` reads Kinoko's pages same-origin with plain GETs, which
      carry no foreign `Origin`. The browser still sends
      `Host: evil.example`, so the request is refused here.
    * **A local build behind a reverse proxy.** Proxied requests carry the
      public host and usually no `Origin`, so `/mcp` (which has no auth)
      would be public. They are refused here too.

  `KinokoWeb.Endpoint.call/2` runs it first, before Phoenix dispatches the
  LiveView socket, so the console, `/mcp`, the served apps and the socket
  are all covered.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Application.get_env(:kinoko, :mode) != :local or local_host?(conn.host) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Kinoko answers only on localhost.\n")
      |> halt()
    end
  end

  @doc "Whether `host` (no port) is a loopback name Kinoko answers on."
  @spec local_host?(String.t() | nil) :: boolean()
  def local_host?(host) when is_binary(host) do
    case String.downcase(host) do
      h when h in ["localhost", "127.0.0.1", "[::1]", "::1"] -> true
      h -> String.ends_with?(h, ".localhost") and h != ".localhost"
    end
  end

  def local_host?(_host), do: false
end
