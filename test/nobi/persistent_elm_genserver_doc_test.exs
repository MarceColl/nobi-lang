defmodule Nobi.PersistentElmGenServerDocTest do
  # The moduledoc's counter example, run against the sandboxed Repo (shared
  # mode, so the server process reaches the connection).
  use Nobi.DataCase, async: false

  alias Nobi.PersistentElmGenServer

  setup do
    on_exit(fn ->
      if pid = PersistentElmGenServer.whereis("counter:demo"), do: GenServer.stop(pid)
    end)
  end

  doctest Nobi.PersistentElmGenServer
end
