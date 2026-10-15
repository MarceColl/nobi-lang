defmodule Kinoko.Exec.Worker do
  @moduledoc """
  Runs one evaluation in a process of its own, bounded in time and memory,
  and hands back its answer or why it has none.

  The worker is spawned monitored with `max_heap_size` set from its first
  instruction (`kill: true`, the bytes of the binaries it holds counted,
  since a string's bytes live off the process heap). The caller waits for
  the answer for at most `timeout` ms, then kills the worker and waits for
  its `DOWN`. A guardian process holds the same deadline independently and
  kills the worker should the caller die first, so no worker outlives its
  call or its caller.

  A worker's answer is copied into the caller, which has no heap limit of
  its own. So before handing a value back the worker weighs it, walking it
  node by node in ordinary (preemptible) code, as Rust's `Machine::bounded`
  does, and answers `"result too large"` past `max_result` nodes: a value
  built by sharing (a list holding itself twice, forty times over) is
  small in the worker and astronomically large once copied.
  """

  @default_timeout 5_000
  @default_heap div(1_073_741_824, :erlang.system_info(:wordsize))
  @default_result 1_000_000
  # A string counts one node more for each this many bytes (Rust's
  # `BYTES_PER_STEP`).
  @bytes_per_node 64

  @unloaded :kinoko_exec_unloaded

  @type error :: %{code: String.t(), message: String.t()}

  @doc """
  Runs `fun` (no arguments) in a bounded worker.

  `{:ok, value}`, or `{:error, %{code, message}}` with code `"runtime"` (a
  thrown `{:yabu_error, message}`), `"timeout"`, `"heap"`, `"unloaded"`
  (`Kinoko.Exec.unload/1` stopped it) or `"internal"` (any other crash, its
  message included).

  Options: `:timeout` (ms, default #{@default_timeout}), `:max_heap_size`
  (words, default 1 GB's worth) and `:max_result` (nodes the answer may
  weigh, default #{@default_result}; `:infinity` skips weighing, for an
  answer the caller knows to be small).
  """
  @spec run((-> term()), keyword()) :: {:ok, term()} | {:error, error}
  def run(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    heap = Keyword.get(opts, :max_heap_size, @default_heap)
    max_result = Keyword.get(opts, :max_result, @default_result)
    caller = self()
    ref = make_ref()

    # The heap limit holds from the worker's first instruction.
    {pid, monitor} =
      :erlang.spawn_opt(fn -> send(caller, {ref, evaluate(fun, max_result)}) end, [
        :monitor,
        {:max_heap_size,
         %{size: heap, kill: true, error_logger: false, include_shared_binaries: true}}
      ])

    guard(pid, caller, timeout)

    receive do
      {^ref, answer} ->
        Process.demonitor(monitor, [:flush])
        answer

      # Killed by its heap limit.
      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:error, %{code: "heap", message: "evaluation used more than #{heap} words of memory"}}

      {:DOWN, ^monitor, :process, ^pid, @unloaded} ->
        {:error, %{code: "unloaded", message: "the image was unloaded while it ran"}}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, %{code: "internal", message: "the evaluation died: #{inspect(reason)}"}}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        # It may have answered just before it was killed.
        receive do
          {^ref, _} -> :ok
        after
          0 -> :ok
        end

        {:error, %{code: "timeout", message: "evaluation took more than #{timeout} ms"}}
    end
  end

  @doc """
  The exit reason `Kinoko.Exec.unload/1` stops a worker running the
  unloaded image with; the caller then answers code `"unloaded"`.
  """
  def unloaded_reason, do: @unloaded

  # The worker's deadline, kept by a guardian of its own rather than by the
  # caller alone: should the caller die (killed, or its own process timed
  # out) the worker dies with it, and in any case at the deadline. The
  # guardian ends when the worker does.
  defp guard(pid, caller, timeout) do
    spawn(fn ->
      worker = Process.monitor(pid)
      owner = Process.monitor(caller)

      receive do
        {:DOWN, ^worker, :process, _, _} -> :ok
        {:DOWN, ^owner, :process, _, _} -> Process.exit(pid, :kill)
      after
        timeout -> Process.exit(pid, :kill)
      end
    end)
  end

  defp evaluate(fun, max_result) do
    value = fun.()

    if max_result == :infinity or weigh([value], max_result) do
      {:ok, value}
    else
      {:error, %{code: "runtime", message: "result too large"}}
    end
  catch
    :throw, {:yabu_error, message} ->
      {:error, %{code: "runtime", message: message}}

    kind, reason ->
      {:error, %{code: "internal", message: Exception.format(kind, reason, __STACKTRACE__)}}
  end

  # Whether the values in `stack` weigh no more than `left` nodes, walked
  # with an explicit stack (a value may nest far deeper than recursion
  # should go). A node is a term or a list cell. A record's or variant's
  # names and a map's keys are walked too; a closure's captured values are
  # part of what is copied.
  defp weigh([], left), do: left >= 0
  defp weigh(_, left) when left < 0, do: false

  defp weigh([v | rest], left) do
    case v do
      b when is_binary(b) ->
        weigh(rest, left - 1 - div(byte_size(b), @bytes_per_node))

      l when is_list(l) ->
        weigh_list(l, rest, left - 1)

      # Charged its size before its entries are spread on the stack.
      m when is_map(m) and map_size(m) >= left ->
        false

      m when is_map(m) ->
        weigh(Enum.reduce(m, rest, fn {k, x}, acc -> [k, x | acc] end), left - 1 - map_size(m))

      t when is_tuple(t) ->
        weigh(Tuple.to_list(t) ++ rest, left - 1)

      f when is_function(f) ->
        weigh(captured(f) ++ rest, left - 1)

      _ ->
        weigh(rest, left - 1)
    end
  end

  defp weigh_list([], rest, left), do: weigh(rest, left)
  defp weigh_list(_, _, left) when left < 0, do: false
  defp weigh_list([x | xs], rest, left), do: weigh_list(xs, [x | rest], left - 1)
  # An improper tail is no Yabu value, but costs no more to count.
  defp weigh_list(tail, rest, left), do: weigh([tail | rest], left)

  defp captured(f) do
    case Function.info(f, :env) do
      {:env, env} when is_list(env) -> env
      _ -> []
    end
  end
end
