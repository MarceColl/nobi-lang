defmodule Kinoko.Elm.Runtime do
  @moduledoc """
  The host-agnostic core shared by `Kinoko.ElmGenServer` and `KinokoWeb.ElmLiveView`.

  It runs `init`/`update`, performs every effect that only needs a process
  (async work, reply, send, timers), records the timeline, and hands back the
  effects only the host can perform (`stop`, navigation, flash, ...).

  A host calls:

    * `init/4` once, then `step/2` for each msg it receives itself (casts,
      calls, LiveView events)
    * `info/2` for every process message — it unwraps msgs produced by our own
      effects (attributing them to the effect) and answers timeline requests

  Each returns `{runtime, host_effects}`.

  ## Time travel

  Every msg entry in the timeline carries a `:seq` number and the `:state`
  `update/2` produced for it. Since `update/2` is pure, those snapshots are the
  whole history: `travel/2` makes `view_state/1` return a past snapshot without
  re-running anything. Msgs keep flowing into the live state meanwhile (effects
  in flight still land), and `resume/1` returns to it.
  """

  alias Kinoko.Elm.Timeline

  @timeline_limit 200

  defstruct [
    :module,
    :state,
    :started_at,
    timeline: :queue.new(),
    timeline_len: 0,
    next_id: 1,
    # effect id => {started_at_us, description}, until its msg comes back
    pending: %{},
    perform?: true,
    # (state, seq -> any) or {(state, seq, acc -> acc), acc}, called after each
    # update and before its effects; nil = none
    on_step: nil,
    # seq of the last recorded msg; init is 0
    seq: -1,
    # {seq, state} while time traveling
    viewing: nil
  ]

  @type t :: %__MODULE__{}
  @type host_effects :: [Kinoko.Elm.Effect.t()]

  @doc """
  Runs `init_fun` (which calls the module's init) and performs its effects.

  `init_msg` is what the timeline shows for it. With `perform: false`, process
  effects are dropped and only host effects are returned — used for a LiveView's
  disconnected render, whose process is thrown away.

  `on_step: fn state, seq -> ... end` is called with the live state after `init`
  and every `update`, before that step's effects are performed. If it raises,
  nothing is performed. Time travel does not affect it, and it fires with
  `perform: false` too (only the effects are dropped, never the hook).

  A hook that needs memory between steps passes `on_step: {fun, acc}` instead:
  `fun.(state, seq, acc)` returns the next `acc`, which the runtime keeps for
  the following step. `Kinoko.PersistentElmGenServer` keeps its last written
  state and seq that way.
  """
  @spec init(module(), term(), (-> {term(), term()}), keyword()) :: {t(), host_effects()}
  def init(module, init_msg, init_fun, opts \\ []) do
    runtime = %__MODULE__{
      module: module,
      started_at: System.monotonic_time(:microsecond),
      perform?: Keyword.get(opts, :perform, true),
      on_step: Keyword.get(opts, :on_step)
    }

    {state, effects} = expect_step!(module, :init, init_fun.())
    runtime |> record_msg(init_msg, nil, state) |> notify() |> perform(effects)
  end

  @doc "Routes `msg` through the module's `update/2`."
  @spec step(t(), term(), map() | nil) :: {t(), host_effects()}
  def step(%__MODULE__{module: module} = runtime, msg, origin \\ nil) do
    {state, effects} = expect_step!(module, :update, module.update(msg, runtime.state))
    runtime |> record_msg(msg, origin, state) |> notify() |> perform(effects)
  end

  @doc "Handles a raw process message."
  @spec info(t(), term()) :: {t(), host_effects()}
  def info(runtime, {__MODULE__, :timeline, pid, ref}) do
    send(pid, {ref, timeline(runtime)})
    {runtime, []}
  end

  def info(runtime, {__MODULE__, id, msg}) when is_integer(id) do
    case Map.pop(runtime.pending, id) do
      {{started_at, effect}, pending} ->
        took_us = elapsed(runtime) - started_at
        step(%{runtime | pending: pending}, msg, %{id: id, effect: effect, took_us: took_us})

      {nil, _pending} ->
        step(runtime, msg)
    end
  end

  def info(runtime, msg), do: step(runtime, msg)

  @doc "Timeline entries, oldest first. See `Kinoko.Elm.Timeline`."
  def timeline(runtime), do: :queue.to_list(runtime.timeline)

  ## Time travel

  @doc "Shows the state as it was right after msg `seq`. Travelling to the latest msg resumes."
  @spec travel(t(), non_neg_integer()) :: {:ok, t()} | {:error, :not_in_history}
  def travel(%__MODULE__{seq: seq} = runtime, seq), do: {:ok, resume(runtime)}

  def travel(runtime, seq) do
    case Enum.find(timeline(runtime), &match?(%{kind: :msg, seq: ^seq}, &1)) do
      %{state: state} -> {:ok, %{runtime | viewing: {seq, state}}}
      nil -> {:error, :not_in_history}
    end
  end

  @doc "Returns to the live state."
  def resume(runtime), do: %{runtime | viewing: nil}

  @doc "The seq being viewed, or `nil` when live."
  def viewing(%__MODULE__{viewing: {seq, _state}}), do: seq
  def viewing(%__MODULE__{viewing: nil}), do: nil

  @doc "The state to render: a past snapshot while travelling, the live state otherwise."
  def view_state(%__MODULE__{viewing: {_seq, state}}), do: state
  def view_state(%__MODULE__{state: state}), do: state

  @doc "Seq of the oldest msg still in history and of the latest one."
  def history_range(runtime) do
    first = Enum.find_value(timeline(runtime), runtime.seq, &(&1.kind == :msg && &1.seq))
    {first, runtime.seq}
  end

  defp expect_step!(_module, _fun, {_state, _effects} = step), do: step

  defp expect_step!(module, fun, other) do
    raise ArgumentError,
          "#{inspect(module)}.#{fun} must return {state, effects}, got: #{inspect(other)}"
  end

  ## Timeline

  defp elapsed(runtime), do: System.monotonic_time(:microsecond) - runtime.started_at

  defp record_msg(runtime, msg, origin, state) do
    seq = runtime.seq + 1
    entry = %{kind: :msg, seq: seq, msg: msg, origin: origin, state: state}
    record(%{runtime | seq: seq, state: state}, entry)
  end

  defp notify(%__MODULE__{on_step: nil} = runtime), do: runtime

  defp notify(%__MODULE__{on_step: {hook, acc}} = runtime) do
    %{runtime | on_step: {hook, hook.(runtime.state, runtime.seq, acc)}}
  end

  defp notify(%__MODULE__{on_step: hook} = runtime) do
    hook.(runtime.state, runtime.seq)
    runtime
  end

  defp record(runtime, entry) do
    timeline = :queue.in(Map.put(entry, :at, elapsed(runtime)), runtime.timeline)

    if runtime.timeline_len < @timeline_limit do
      %{runtime | timeline: timeline, timeline_len: runtime.timeline_len + 1}
    else
      %{runtime | timeline: :queue.drop(timeline)}
    end
  end

  ## Effect interpreter — the only place side effects happen.
  ## Nothing here waits on the outside world: async work is handed to its own
  ## process, and everything else is a non-blocking send.

  defp perform(runtime, effects) do
    {runtime, host} =
      effects
      |> List.wrap()
      |> List.flatten()
      |> Enum.reduce({runtime, []}, fn effect, {runtime, host} ->
        id = runtime.next_id
        description = Timeline.describe(effect)

        runtime =
          record(%{runtime | next_id: id + 1}, %{kind: :effect, id: id, effect: description})

        case dispatch(effect, id, runtime.perform?) do
          :ok -> {runtime, host}
          :pending -> {track(runtime, id, description), host}
          :host -> {runtime, [effect | host]}
        end
      end)

    {runtime, Enum.reverse(host)}
  end

  defp track(runtime, id, description) do
    {:value, %{at: started_at}} = :queue.peek_r(runtime.timeline)
    %{runtime | pending: Map.put(runtime.pending, id, {started_at, description})}
  end

  @process_effects [:async, :reply, :send, :after_ms]

  defp dispatch(effect, _id, _perform? = false) when elem(effect, 0) in @process_effects, do: :ok

  defp dispatch({:async, request, to_msg}, id, true) do
    server = self()
    {:ok, _pid} = Task.start(fn -> send(server, {__MODULE__, id, to_msg.(execute(request))}) end)
    :pending
  end

  defp dispatch({:reply, from, value}, _id, true), do: GenServer.reply(from, value)

  defp dispatch({:send, :self, msg}, id, true) do
    send(self(), {__MODULE__, id, msg})
    :pending
  end

  defp dispatch({:send, dest, msg}, _id, true) do
    send(dest, msg)
    :ok
  end

  defp dispatch({:after_ms, ms, msg}, id, true) do
    Process.send_after(self(), {__MODULE__, id, msg}, ms)
    :pending
  end

  defp dispatch(_host_effect, _id, _perform?), do: :host

  # Runs inside the effect's own process, never in the host.
  defp execute({:http, req_options}) do
    Req.request(req_options)
  rescue
    e -> {:error, e}
  end

  defp execute(:now), do: DateTime.utc_now()

  defp execute({:random, range}), do: Enum.random(range)

  defp execute({:task, fun}) do
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
