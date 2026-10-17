defmodule NobiWeb.PageControllerTest do
  # `/` is the deployment catch-all wherever `:mcp_enabled` is set (test
  # included); PageController serves it only without it (prod). The
  # controller is called directly here.
  use NobiWeb.ConnCase

  test "home renders", %{conn: conn} do
    conn =
      conn
      |> bypass_through(NobiWeb.Router, [:browser])
      |> get("/")
      |> NobiWeb.PageController.call(:home)

    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
