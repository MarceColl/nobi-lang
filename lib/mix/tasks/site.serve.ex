defmodule Mix.Tasks.Site.Serve do
  @shortdoc "Serves site/dist on http://localhost:4124"

  @moduledoc """
  Previews the built homepage (`mix site.build` first):

      mix site.serve

  Serves `site/dist` on http://localhost:4124 with Bandit and `Plug.Static`,
  without starting Kinoko itself. The module is also the Plug it serves.
  """

  use Mix.Task

  @behaviour Plug

  @port 4124
  @dist "site/dist"

  @impl Mix.Task
  def run(_args) do
    unless File.exists?(Path.join(@dist, "index.html")),
      do: Mix.raise("#{@dist}/index.html is missing; run `mix site.build` first")

    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Bandit.start_link(plug: __MODULE__, ip: :loopback, port: @port, startup_log: false)
    Mix.shell().info("Serving #{@dist} at http://localhost:#{@port}")
    Process.sleep(:infinity)
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: []} = conn, opts),
    do: call(%{conn | path_info: ["index.html"], request_path: "/index.html"}, opts)

  def call(conn, _opts) do
    conn = Plug.Static.call(conn, Plug.Static.init(at: "/", from: @dist))
    if conn.halted, do: conn, else: Plug.Conn.send_resp(conn, 404, "not found")
  end
end
