defmodule NobiWeb.Router do
  use NobiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NobiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # MCP over streamable HTTP: JSON in and out, no session or CSRF. The
  # endpoint leaves the body unparsed for this path (see `NobiWeb.Endpoint`).
  # It has no auth yet, so it is mounted only where `:mcp_enabled` is set
  # (dev, test and the local `nobi` build; never a server build). See
  # `NobiWeb.McpController`.
  if Application.compile_env(:nobi, :mcp_enabled, false) do
    pipeline :mcp do
      plug :accepts, ["json"]
      plug NobiWeb.Mcp.Guard
    end

    scope "/", NobiWeb do
      pipe_through :mcp

      post "/mcp", McpController, :post
      get "/mcp", McpController, :not_allowed
      delete "/mcp", McpController, :not_allowed
    end
  end

  # Nobi's own pages live under the reserved prefix `/_` where deployments
  # are served (`:mcp_enabled`), so they never shadow an app's paths.
  @mcp_enabled Application.compile_env(:nobi, :mcp_enabled, false)
  @nobi_prefix if @mcp_enabled, do: "/_", else: "/"

  scope @nobi_prefix, NobiWeb do
    pipe_through :browser

    if !@mcp_enabled, do: get("/", PageController, :home)
    live "/elm", ElmDemoLive
    live "/sim", SimLive
  end

  # The console: Nobi's own UI, never served through a deployment.
  if @mcp_enabled do
    scope "/_", NobiWeb.Console do
      pipe_through :browser

      live_session :console, on_mount: NobiWeb.Console.Live do
        live "/", IndexLive
        live "/u/:universe", UniverseLive
        live "/d/:name", DeploymentLive
      end
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", NobiWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:nobi, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/_/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: NobiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Deployment serving: every path no route above took goes to the deployment
  # the request's host resolves to (`NobiWeb.DeploymentLive`). The reserved
  # prefixes answer 404 here instead, so an app never receives them; routes
  # under them must be declared above. Dev and test only, like `/mcp`.
  if @mcp_enabled do
    scope "/", NobiWeb do
      pipe_through :browser

      for prefix <- ~w(_ mcp live assets phoenix images favicon.ico) do
        match :*, "/#{prefix}", ReservedController, :not_found
        match :*, "/#{prefix}/*rest", ReservedController, :not_found
      end
    end

    pipeline :deployment do
      plug NobiWeb.DeploymentStatus
    end

    # The deployment is resolved from the request's host here, on the
    # server, and signed into the LiveView session: the connected
    # LiveView never trusts the URL the client sends.
    scope "/", NobiWeb do
      pipe_through [:browser, :deployment]

      live_session :deployment,
        session: {NobiWeb.DeploymentStatus, :session, []},
        root_layout: {NobiWeb.Layouts, :nobi_root} do
        live "/*path", DeploymentLive
      end
    end
  end
end
