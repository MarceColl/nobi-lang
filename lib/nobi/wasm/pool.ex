defmodule Nobi.Wasm.Pool do
  @moduledoc """
  Bounds how many WASM calls run at once: `:concurrency` slots, then a FIFO
  of at most `:queue` waiters; a call past both is `{:error, "wasm busy"}`
  at once, so threads never pile up.

  Each granted slot runs its job in a monitored runner process, which
  replies to the caller itself. The slot is freed only when the runner
  exits, never when the caller stops waiting: a runner whose caller timed
  out still waits for its native call to end (`Nobi.Wasm`), so real CPU use
  never exceeds the slot count. A waiter whose deadline has passed is
  dropped when its turn comes; its caller has already answered `"timeout"`.
  """

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  `job`'s answer, run in a slot, or `"wasm busy"`/`"timeout"`. Waits no
  longer than `deadline` (monotonic ms).
  """
  @spec run((-> term()), integer(), keyword()) :: term()
  def run(job, deadline, cfg) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {:error, "timeout"}
    else
      try do
        GenServer.call(__MODULE__, {:run, job, deadline, cfg[:concurrency], cfg[:queue]}, left)
      catch
        :exit, {:timeout, _} -> {:error, "timeout"}
      end
    end
  end

  @doc "How many slots are in use and how many callers wait."
  @spec load() :: %{running: non_neg_integer(), waiting: non_neg_integer()}
  def load, do: GenServer.call(__MODULE__, :load)

  @impl true
  def init(nil), do: {:ok, %{running: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call({:run, job, deadline, concurrency, queue}, from, s) do
    cond do
      map_size(s.running) < concurrency ->
        {:noreply, start(s, job, from)}

      :queue.len(s.waiting) < queue ->
        {:noreply, %{s | waiting: :queue.in({job, from, deadline}, s.waiting)}}

      true ->
        {:reply, {:error, "wasm busy"}, s}
    end
  end

  def handle_call(:load, _from, s),
    do: {:reply, %{running: map_size(s.running), waiting: :queue.len(s.waiting)}, s}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    {:noreply, next(%{s | running: Map.delete(s.running, ref)})}
  end

  defp start(s, job, from) do
    {_pid, ref} = spawn_monitor(fn -> GenServer.reply(from, safely(job)) end)
    %{s | running: Map.put(s.running, ref, true)}
  end

  # The next waiter still within its deadline, if any.
  defp next(s) do
    case :queue.out(s.waiting) do
      {:empty, _} ->
        s

      {{:value, {job, from, deadline}}, rest} ->
        s = %{s | waiting: rest}

        if deadline > System.monotonic_time(:millisecond),
          do: start(s, job, from),
          else: next(s)
    end
  end

  defp safely(job) do
    job.()
  rescue
    e -> {:error, "wasm: " <> Exception.message(e)}
  catch
    kind, reason -> {:error, "wasm: " <> Exception.format_banner(kind, reason)}
  end
end
