defmodule Kinoko.Data.Opener do
  @moduledoc """
  Owns one open deployment file: the `Kinoko.Data.Repo` instance on it.

  One opener per file, registered in `Kinoko.Data.Registry` under the
  file's path and started under `Kinoko.Data.Supervisor`, so opening is
  single-flight: the first `open/2` starts it (creating the file and the
  meta tables in `init/1`), every other finds it. `ecto_sqlite3`'s
  migration lock is a no-op, so this is what keeps two processes from
  creating the meta tables at once.

  The registry entry's value is the repo pid once the file is ready, so an
  open of a ready file is one registry lookup.

  The repo is linked: if it dies, the opener stops, and the next `open/2`
  starts a fresh one (`restart: :temporary`). Stopping drops the repo's
  schema cache entries (`Kinoko.Data.Cache.drop/1`).
  """

  use GenServer, restart: :temporary

  alias Kinoko.Data.{Cache, Repo, Schema}

  @registry Kinoko.Data.Registry
  @supervisor Kinoko.Data.Supervisor

  @doc """
  The repo of the file at `path`, opening it if it is not open. Options:
  `busy_timeout:` (ms) for the repo, used only by the open that starts it.
  """
  @spec open(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(path, opts) do
    case Registry.lookup(@registry, path) do
      [{_opener, repo}] when is_pid(repo) -> {:ok, repo}
      _ -> start(path, opts)
    end
  end

  defp start(path, opts) do
    spec = {__MODULE__, Keyword.put(Keyword.take(opts, [:busy_timeout]), :path, path)}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, opener} -> repo(opener)
      {:error, {:already_started, opener}} -> repo(opener)
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo(opener) do
    GenServer.call(opener, :repo)
  catch
    :exit, reason -> {:error, {:opener_down, reason}}
  end

  @doc "Closes the file at `path` if it is open."
  @spec close(String.t()) :: :ok
  def close(path) do
    case Registry.lookup(@registry, path) do
      [{opener, _}] ->
        _ = DynamicSupervisor.terminate_child(@supervisor, opener)
        :ok

      [] ->
        :ok
    end
  end

  @doc false
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, path}})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))

    repo_opts = [name: nil, database: path] ++ Keyword.take(opts, [:busy_timeout])

    with :ok <- create_wal(path),
         {:ok, repo} <- Repo.start_link(repo_opts),
         :ok <- Schema.create_meta(repo) do
      {_, _} = Registry.update_value(@registry, path, fn _ -> repo end)
      {:ok, %{repo: repo, path: path}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # A new file is made, in WAL mode, before the pool connects: the pool's
  # connections each switch a new file to WAL as they connect, and two
  # doing so at once fail with "database is locked".
  defp create_wal(path) do
    if File.exists?(path) do
      :ok
    else
      with {:ok, conn} <- Exqlite.Sqlite3.open(path) do
        try do
          Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = wal")
        after
          Exqlite.Sqlite3.close(conn)
        end
      end
    end
  end

  @impl true
  def handle_call(:repo, _from, state), do: {:reply, {:ok, state.repo}, state}

  @impl true
  def handle_info({:EXIT, repo, reason}, %{repo: repo} = state),
    do: {:stop, {:shutdown, {:repo_down, reason}}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{repo: repo}) do
    Cache.drop(repo)

    if Process.alive?(repo) do
      try do
        Supervisor.stop(repo)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
