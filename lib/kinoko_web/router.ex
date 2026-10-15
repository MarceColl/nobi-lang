defmodule KinokoWeb.Router do
  use KinokoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KinokoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # MCP over streamable HTTP: JSON in and out, no session or CSRF. The
  # endpoint leaves the body unparsed for this path (see `KinokoWeb.Endpoint`).
  pipeline :mcp do
    plug :accepts, ["json"]
    plug KinokoWeb.Mcp.Guard
  end

  scope "/", KinokoWeb do
    pipe_through :mcp

    post "/mcp", McpController, :post
    get "/mcp", McpController, :not_allowed
    delete "/mcp", McpController, :not_allowed
  end

  scope "/", KinokoWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/elm", ElmDemoLive
    live "/sim", SimLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", KinokoWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:kinoko, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: KinokoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
