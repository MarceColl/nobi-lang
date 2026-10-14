defmodule KinokoWeb.PageController do
  use KinokoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
