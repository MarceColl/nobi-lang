defmodule KinokoWeb.PageControllerTest do
  # `/` is the deployment catch-all wherever `:mcp_enabled` is set (test
  # included); PageController serves it only without it (prod). The
  # controller is called directly here.
  use KinokoWeb.ConnCase

  test "home renders", %{conn: conn} do
    conn =
      conn
      |> bypass_through(KinokoWeb.Router, [:browser])
      |> get("/")
      |> KinokoWeb.PageController.call(:home)

    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
