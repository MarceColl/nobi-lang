defmodule KinokoWeb.ReservedController do
  @moduledoc """
  Answers 404 for a path under a reserved prefix (`/_`, `/mcp`, `/live`,
  `/assets`, `/phoenix`, `/images`, `/favicon.ico`) that no Kinoko route
  took, so the deployment catch-all never receives it.
  """
  use KinokoWeb, :controller

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(html: KinokoWeb.ErrorHTML, json: KinokoWeb.ErrorJSON)
    |> render(:"404")
  end
end
