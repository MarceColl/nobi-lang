defmodule Nobi.ParentWatch do
  @moduledoc """
  Stops Nobi when the Burrito wrapper that launched it goes away.

  Burrito's wrapper runs the BEAM as a child process and forwards no
  signals, so `kill <wrapper pid>` would leave the server running, adopted
  by init. Under Burrito (`__BURRITO` set) `nobi start` starts this
  process: it reads the VM's parent pid once, checks it every 2 seconds,
  and calls `System.stop/0` once the parent pid changes.

  The parent pid comes from `/proc/<pid>/stat` on Linux (minimal images have
  no `ps`) and from `ps -o ppid= -p <pid>` elsewhere. When it cannot be read
  at start the watch does not start; an unreadable value later is no
  change.
  """

  use GenServer

  @interval 2_000

  @type ppid :: pos_integer() | nil

  @doc """
  Starts the watch. Options, for tests: `:ppid` (a 0-arity fun returning the
  parent pid or `nil`), `:interval` (ms), `:on_orphan` (0-arity fun, default
  `System.stop/0`) and `:name` (default `Nobi.ParentWatch`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Starts the watch under `Nobi.Supervisor` when running under Burrito."
  @spec maybe_start(Nobi.Local.env()) :: :ok
  def maybe_start(env) do
    if env["__BURRITO"], do: Supervisor.start_child(Nobi.Supervisor, __MODULE__)
    :ok
  end

  @doc """
  The decision, from the parent pid read at start and the one read now:
  `:orphaned` once it has changed, `:ok` while it is the same or unreadable.
  """
  @spec decide(pos_integer(), ppid()) :: :ok | :orphaned
  def decide(_parent, nil), do: :ok
  def decide(parent, parent), do: :ok
  def decide(_parent, _other), do: :orphaned

  @impl true
  def init(opts) do
    ppid = Keyword.get(opts, :ppid, &os_ppid/0)

    case ppid.() do
      nil ->
        :ignore

      parent ->
        state = %{
          parent: parent,
          ppid: ppid,
          interval: Keyword.get(opts, :interval, @interval),
          on_orphan: Keyword.get(opts, :on_orphan, &System.stop/0)
        }

        schedule(state)
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:check, state) do
    case decide(state.parent, state.ppid.()) do
      :ok ->
        schedule(state)
        {:noreply, state}

      :orphaned ->
        state.on_orphan.()
        {:noreply, state}
    end
  end

  defp schedule(state), do: Process.send_after(self(), :check, state.interval)

  @doc "This VM's parent pid, or `nil` when it cannot be read."
  @spec os_ppid() :: ppid()
  def os_ppid do
    pid = System.pid()

    case :os.type() do
      {:unix, :linux} -> proc_ppid(File.read("/proc/#{pid}/stat"))
      _ -> ps_ppid(pid)
    end
  end

  # /proc/<pid>/stat: "pid (comm) state ppid ..."; comm may hold spaces and
  # parentheses, so the fields start after the last ")".
  defp proc_ppid({:ok, stat}) do
    with [_, rest] <- :binary.split(stat, ")", [:global]) |> split_last(),
         [_state, ppid | _] <- String.split(rest),
         {n, ""} <- Integer.parse(ppid) do
      n
    else
      _ -> nil
    end
  end

  defp proc_ppid(_), do: nil

  defp split_last(parts) when length(parts) >= 2 do
    {init, [last]} = Enum.split(parts, -1)
    [Enum.join(init, ")"), last]
  end

  defp split_last(_), do: nil

  defp ps_ppid(pid) do
    with ps when is_binary(ps) <- System.find_executable("ps"),
         {out, 0} <- System.cmd(ps, ["-o", "ppid=", "-p", pid], stderr_to_stdout: true),
         {n, ""} <- Integer.parse(String.trim(out)) do
      n
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
