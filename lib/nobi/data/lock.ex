defmodule Nobi.Data.Lock do
  @moduledoc """
  A deployment's write lock: one writer at a time per file, waited for in
  the BEAM, before any connection is checked out.

  SQLite serializes writers itself, but a writer waiting on SQLite's lock
  (`busy_timeout`) waits holding a pool connection; with a pool of 2, one
  long transaction and one waiting writer leave no connection for reads.
  Taking this lock first, a waiting writer holds nothing, so reads (WAL)
  never stall behind writers.

  The lock is served by the file's `Nobi.Data.Opener`, registered in
  `Nobi.Data.Registry` under `{:write_lock, repo}`. Waiters queue in
  order. A waiter not granted it within the file's `busy_timeout` gets
  `Nobi.Data.LockError` (`:busy`), as SQLite's own wait would end; an
  opener that is gone raises it with `:down`. The lock is released when
  the holder's function returns or raises (so on commit or rollback), or
  when the holder dies.

  It is re-entrant within a process: a write inside `with_lock/2` (a
  `Nobi.Data` call inside `Nobi.Data.transaction/2`, a schema sync
  inside an insert) runs under the lock already held.

  ## Protocol

  The waiter sends the opener `{:nobi_lock, :acquire, pid, ref}` and
  waits for `{:nobi_lock, ref, :granted}` or `{:nobi_lock, ref,
  :busy}` (or the opener's death); it releases with `{:nobi_lock,
  :release, ref}`.
  """

  alias Nobi.Data.LockError

  @registry Nobi.Data.Registry

  @doc "The registry key the lock of `repo`'s file is served under."
  @spec key(pid()) :: {:write_lock, pid()}
  def key(repo), do: {:write_lock, repo}

  @doc """
  Runs `fun` holding `repo`'s write lock (re-entrant), and returns what it
  returns. Raises `Nobi.Data.LockError` when the lock cannot be had.
  """
  @spec with_lock(pid(), (-> result)) :: result when result: term()
  def with_lock(repo, fun) do
    held = {__MODULE__, repo}

    if Process.get(held) do
      fun.()
    else
      {server, ref} = acquire!(repo)
      Process.put(held, true)

      try do
        fun.()
      after
        Process.delete(held)
        send(server, {:nobi_lock, :release, ref})
      end
    end
  end

  @doc "Whether the calling process holds `repo`'s write lock."
  @spec held?(pid()) :: boolean()
  def held?(repo), do: Process.get({__MODULE__, repo}) == true

  defp acquire!(repo) do
    case Registry.lookup(@registry, key(repo)) do
      [{server, _}] ->
        ref = make_ref()
        mon = Process.monitor(server)
        send(server, {:nobi_lock, :acquire, self(), ref})

        receive do
          {:nobi_lock, ^ref, :granted} ->
            Process.demonitor(mon, [:flush])
            {server, ref}

          {:nobi_lock, ^ref, :busy} ->
            Process.demonitor(mon, [:flush])
            raise LockError, reason: :busy

          {:DOWN, ^mon, :process, _, _} ->
            raise LockError, reason: :down
        end

      [] ->
        raise LockError, reason: :down
    end
  end
end
