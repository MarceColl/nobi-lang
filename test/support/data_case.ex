defmodule Kinoko.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. The database is SQLite, which
  has a single writer and the sandbox holds each test's transaction open,
  so tests that write must not be `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Kinoko.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Kinoko.DataCase
    end
  end

  setup tags do
    Kinoko.DataCase.setup_sandbox(tags)
    :ok
  end

  # Sync tests may reach a universe (some only through a default name, such
  # as "main"); none of its CodeDbs may outlive the test.
  setup tags do
    unless tags[:async], do: Kinoko.UniverseHelpers.stop_universes_on_exit()
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Kinoko.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # SQLite has one writer. The previous test's sandbox transaction is rolled
    # back asynchronously after it stops, so it may still hold the write lock.
    # A transaction that has read cannot wait for that lock (SQLite answers
    # "Database busy" at once), so take it now, as the first statement, where
    # busy_timeout makes it wait. The test then holds it until it ends.
    Ecto.Adapters.SQL.query!(Kinoko.Repo, "DELETE FROM universes WHERE 0")
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
