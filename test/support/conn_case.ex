defmodule KinokoWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. The database is SQLite, which
  has a single writer and the sandbox holds each test's transaction open,
  so tests that write must not be `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint KinokoWeb.Endpoint

      use KinokoWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import KinokoWeb.ConnCase
    end
  end

  setup tags do
    Kinoko.DataCase.setup_sandbox(tags)
    unless tags[:async], do: Kinoko.UniverseHelpers.stop_universes_on_exit()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
