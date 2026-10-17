defmodule Nobi.Data.Opener do
  @moduledoc """
  Owns one open deployment file: the `Nobi.Data.Repo` instance on it.

  One opener per file, registered in `Nobi.Data.Registry` under the
  file's path and started under `Nobi.Data.Supervisor`, so opening is
  single-flight: the first `open/2` starts it (creating the file and the
  meta tables in `init/1`), every other finds it. `ecto_sqlite3`'s
  migration lock is a no-op, so this is what keeps two processes from
  creating the meta tables at once.

  The file is opened in `handle_continue/2`, not `init/1`, so a slow open
  does not hold up the supervisor; callers wait on `GenServer.call`. The
  registry entry's value is the repo pid once the file is ready, so an open
  of a ready file is one registry lookup.

  The repo is linked: if it dies, the opener stops, and the next `open/2`
  starts a fresh one (`restart: :temporary`). Stopping drops the repo's
  schema cache entries (`Nobi.Data.Cache.drop/1`).

  ## The write lock

  The opener also serves the file's write lock (`Nobi.Data.Lock`, its
  protocol there), registered as `Nobi.Data.Lock.key(repo)` before the
  repo is handed out. It grants the lock to one holder at a time, in the
  order asked; a waiter still waiting after the file's `busy_timeout` (the
  `busy_timeout:` option, else the repo's config, else 5_000 ms) is told
  `:busy` and dropped. It monitors holder and waiters: a holder's death
  releases the lock, a waiter's drops it from the queue.
  """

  use GenServer, restart: :temporary

  alias Nobi.Data.{Cache, Lock, Repo, Schema}

  @registry Nobi.Data.Registry
  @supervisor Nobi.Data.Supervisor
  @stale_tries 1_000

  @doc """
  The repo of the file at `path`, opening it if it is not open. Options:
  `busy_timeout:` (ms) for the repo, used only by the open that starts it.
  """
  @spec open(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(path, opts), do: open(path, opts, @stale_tries)

  # An opener that just stopped (`close/1`) can linger in the registry
  # for a moment after it is gone: its entry is waited out, never used.
  defp open(path, opts, tries) do
    case Registry.lookup(@registry, path) do
      [{opener, repo}] when is_pid(repo) ->
        if Process.alive?(opener) and Process.alive?(repo),
          do: {:ok, repo},
          else: stale(path, opts, tries)

      _ ->
        start(path, opts, tries)
    end
  end

  defp stale(_path, _opts, 0), do: {:error, :opener_stopping}

  defp stale(path, opts, tries) do
    Process.sleep(1)
    open(path, opts, tries - 1)
  end

  defp start(path, opts, tries) do
    spec = {__MODULE__, Keyword.put(Keyword.take(opts, [:busy_timeout]), :path, path)}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, opener} ->
        repo(opener)

      {:error, {:already_started, opener}} ->
        if Process.alive?(opener), do: repo(opener), else: stale(path, opts, tries)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # No call timeout: the open it waits for is bounded by the file's own
  # waits (`busy_timeout`), and a caller timing out first would only leave
  # an opener that succeeds after its caller gave up.
  defp repo(opener) do
    GenServer.call(opener, :repo, :infinity)
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

    busy_timeout =
      Keyword.get(opts, :busy_timeout) ||
        Keyword.get(Application.get_env(:nobi, Repo, []), :busy_timeout, 5_000)

    state = %{
      repo: nil,
      path: Keyword.fetch!(opts, :path),
      busy_timeout: busy_timeout,
      holder: nil,
      queue: :queue.new(),
      waiting: %{}
    }

    {:ok, state, {:continue, {:open, opts}}}
  end

  # Opening runs after `init/1`, so a slow first open does not hold up the
  # DynamicSupervisor (which starts children one at a time). Callers wait
  # in `GenServer.call(opener, :repo)`, which is answered only after this.
  @impl true
  def handle_continue({:open, opts}, %{path: path} = state) do
    repo_opts = [name: nil, database: path] ++ Keyword.take(opts, [:busy_timeout])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- create_wal(path),
         {:ok, repo} <- Repo.start_link(repo_opts),
         state = %{state | repo: repo},
         :ok <- Schema.create_meta(repo),
         {:ok, _} <- Registry.register(@registry, Lock.key(repo), nil) do
      {_, _} = Registry.update_value(@registry, path, fn _ -> repo end)
      {:noreply, state}
    else
      {:error, reason} -> {:stop, {:shutdown, {:open_failed, reason}}, state}
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

  def handle_info({:nobi_lock, :acquire, pid, ref}, state) do
    mon = Process.monitor(pid)

    if state.holder == nil do
      {:noreply, grant(state, pid, ref, mon)}
    else
      timer = Process.send_after(self(), {:nobi_lock, :expire, ref}, state.busy_timeout)

      {:noreply,
       %{
         state
         | queue: :queue.in(ref, state.queue),
           waiting: Map.put(state.waiting, ref, {pid, mon, timer})
       }}
    end
  end

  def handle_info({:nobi_lock, :release, ref}, %{holder: {_pid, ref, mon}} = state) do
    Process.demonitor(mon, [:flush])
    {:noreply, next(%{state | holder: nil})}
  end

  def handle_info({:nobi_lock, :release, _ref}, state), do: {:noreply, state}

  def handle_info({:nobi_lock, :expire, ref}, state) do
    case Map.pop(state.waiting, ref) do
      {{pid, mon, _timer}, waiting} ->
        Process.demonitor(mon, [:flush])
        send(pid, {:nobi_lock, ref, :busy})
        {:noreply, %{state | waiting: waiting}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{holder: {_, _, mon}} = state),
    do: {:noreply, next(%{state | holder: nil})}

  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    case Enum.find(state.waiting, fn {_ref, {_pid, m, _timer}} -> m == mon end) do
      {ref, {_pid, _mon, timer}} ->
        Process.cancel_timer(timer)
        {:noreply, %{state | waiting: Map.delete(state.waiting, ref)}}

      nil ->
        {:noreply, state}
    end
  end

  defp grant(state, pid, ref, mon) do
    send(pid, {:nobi_lock, ref, :granted})
    %{state | holder: {pid, ref, mon}}
  end

  # The next waiter still waiting gets the lock (refs dropped from
  # `waiting`, by expiry or death, are skipped).
  defp next(state) do
    case :queue.out(state.queue) do
      {{:value, ref}, queue} ->
        case Map.pop(state.waiting, ref) do
          {{pid, mon, timer}, waiting} ->
            Process.cancel_timer(timer)
            grant(%{state | queue: queue, waiting: waiting}, pid, ref, mon)

          {nil, _} ->
            next(%{state | queue: queue})
        end

      {:empty, _} ->
        state
    end
  end

  @impl true
  def terminate(_reason, %{repo: nil}), do: :ok

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
