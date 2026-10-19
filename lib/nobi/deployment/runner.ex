defmodule Nobi.Deployment.Runner do
  @moduledoc """
  A deployment's app, run headless in the caller: what the MCP `send` tool
  does. It opens a path the way a page mount does, then sends messages to
  the app, and every effect really runs, through the interpreter
  `NobiWeb.DeploymentLive` uses (`Nobi.Deployment.Effects`): store
  operations write the deployment's own data file, `Cmd.time.now` and
  `Cmd.random.int` are real, callbacks go back into `update`.

  `run/4`:

    1. reads the deployment, resolves the code it serves once (a
       following deployment's current commit, else its pinned one) and
       matches `path` in its route table to an app and `init`'s arguments;
    2. checks every message as an expression of that app's `Msg` type
       (as `eval` does, on the same code), before anything runs;
    3. runs `init(args…)` and its effects, then for each message
       `update(msg, model)` and its effects.

  Effects run one at a time in the order they were issued, a callback's
  msg goes through `update` at once and its own effects join the end of
  the queue, until the queue is empty. `Cmd.time.after` runs on a virtual
  clock (it starts at 0 and only timers move it): a timer waits until the
  queue is empty, then the earliest one fires, at once, and its msg goes
  through `update` like a callback's. A step "settles" when neither
  effects nor timers are left, so a timer never outlives its step. A step
  may run at most `max_steps` effects (default #{50}; each counts once,
  with or without a callback, a timer when it fires); a step that reaches
  it stops the run there, which is where a loop that re-arms its timer
  ends. A run
  takes at most #{20} messages. `Cmd.wasm.call` runs the real module,
  one call at a time, and a run spends at most #{60} s in WASM calls in
  all; once that is spent, each call left answers `Err("timeout")`. `Cmd.navigate` is reported with its URL but not followed: the
  run stays on its app. An `update` that fails stops the run.

  The report: the app, its arguments, one entry per step (`:init`, then
  each message) holding its effects and the model after it, the final
  model and the final view (an `Html` value), plus the route table
  entries a renderer resolves links against.
  """

  alias Nobi.{Deployment, Exec, Universe}
  alias Nobi.Deployment.Effects
  alias Nobi.Lang.{Format, Routes}

  @max_steps 50
  # The WASM time one run may spend, in ms (`config :nobi, Nobi.Wasm,
  # send_budget_ms:`).
  @wasm_budget_ms 60_000
  @max_messages 20
  # Waiting effects named when the cap stops a step.
  @left_shown 5

  @type entry :: %{
          effect: String.t(),
          value: term(),
          error: String.t() | nil,
          msg: term(),
          note: String.t() | nil
        }

  @type step :: %{
          msg: :init | String.t(),
          effects: [entry()],
          model: term(),
          error: String.t() | nil
        }

  @doc """
  Opens `path` on deployment `name` and sends `messages` (Nobi source, each
  of the app's `Msg` type): `{:ok, report}` or `{:error, message}` when
  nothing could run (no such deployment, no route, a message that does not
  check, more than #{@max_messages} messages). Options: `max_steps` (effects
  per step).
  """
  @spec run(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def run(name, path, messages, opts \\ []) do
    max = Keyword.get(opts, :max_steps, @max_steps)

    with :ok <- message_count(messages),
         {:ok, d} <- deployment(name),
         {:ok, code} <- code(d),
         {:ok, entries} <- route_table(d, code),
         {:ok, app, args} <- match(d, entries, path),
         {:ok, msg_type} <- msg_type(code, app),
         {:ok, msgs} <- check_messages(code, app, msg_type, messages) do
      run = %{
        d: d,
        code: code,
        entries: entries,
        app: app,
        max: max,
        steps: [],
        model: nil,
        model_type: model_type(code, app),
        clock: 0,
        wasm_ms: 0,
        stopped?: false
      }

      run = run |> init(args) |> send_all(Enum.zip(messages, msgs))

      {:ok,
       %{
         deployment: d.name,
         path: path,
         app: app,
         args: args,
         steps: Enum.reverse(run.steps),
         model: run.model,
         model_type: run.model_type,
         view: view(run),
         entries: entries
       }}
    end
  end

  ## Opening

  defp message_count(messages) when length(messages) <= @max_messages, do: :ok

  defp message_count(messages),
    do:
      {:error,
       "send takes at most #{@max_messages} messages, got #{length(messages)}; nothing ran. " <>
         "Split them over several sends: each opens the path afresh, and the store keeps " <>
         "what the earlier ones wrote (the model does not)."}

  defp deployment(name) do
    case Deployment.get(name) do
      {:ok, d} ->
        {:ok, d}

      :error ->
        names = Deployment.list() |> Enum.map(& &1.name) |> Enum.join(", ")

        {:error,
         "no deployment named #{inspect(name)} (deployments: #{if names == "", do: "none", else: names}; list_deployments shows them)"}
    end
  end

  # The code the deployment serves, resolved once for the whole run.
  defp code(%{commit: nil, universe: u}) do
    case Universe.current(u) do
      {:ok, current} -> {:ok, current}
      {:error, e} -> {:error, "deployment's universe #{u} cannot run: #{error_text(e)}"}
    end
  end

  defp code(d) do
    case Deployment.target(d) do
      {:ok, at} -> {:ok, at}
      {:error, e} -> {:error, "deployment #{d.name} cannot run: #{error_text(e)}"}
    end
  end

  defp route_table(d, code) do
    case Universe.routes(code) do
      %{} = tables ->
        case Map.fetch(tables, d.routes) do
          {:ok, entries} ->
            {:ok, entries}

          :error ->
            {:error,
             "deployment #{d.name} serves route table #{d.routes}, which universe " <>
               "#{d.universe} does not define yet: promote a `defroutes #{d.routes}`"}
        end

      {:error, e} ->
        {:error, "deployment #{d.name} cannot run: #{error_text(e)}"}
    end
  end

  defp match(d, entries, path) do
    case Routes.match(entries, path) do
      {:ok, app, args} ->
        {:ok, app, args}

      :not_found ->
        routes =
          Enum.map_join(entries, ", ", fn e ->
            "#{Format.route_pattern(e.segments)} -> #{e.app}"
          end)

        {:error,
         "no route in #{d.routes} matches #{inspect(path)} (its routes: #{routes}); " <>
           "a Uuid param must be a canonical lowercase UUID, an Int plain digits"}
    end
  end

  defp msg_type(code, app) do
    case signature(code, app <> ".update") do
      {:def, [msg, _model], _, _} -> {:ok, msg}
      _ -> {:error, "#{app}.update is not a def of (msg, model) in the code deployed"}
    end
  end

  defp model_type(code, app) do
    case signature(code, app <> ".update") do
      {:def, [_msg, model], _, _} -> model
      _ -> nil
    end
  end

  defp signature(%{signatures: sigs}, symbol), do: Map.get(sigs, symbol)

  # Each message is checked and evaluated as `(source : Msg)` on the
  # deployed code, before anything runs: a bad one runs nothing.
  defp check_messages(code, app, type, messages) do
    shown = Format.type(type)

    messages
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {source, i}, {:ok, acc} ->
      case Universe.eval(code, "(#{source} : #{shown})") do
        {:ok, value, ^type} ->
          {:cont, {:ok, [value | acc]}}

        {:ok, _value, other} ->
          {:halt, {:error, not_msg(i, source, app, "it is a #{Format.type(other)}")}}

        {:error, e} ->
          {:halt, {:error, not_msg(i, source, app, error_text(e))}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      error -> error
    end
  end

  defp not_msg(i, source, app, why),
    do:
      "message #{i} `#{source}` is not a #{app}.Msg the deployed code accepts: #{why}. " <>
        "Nothing ran. Write a value of #{app}.Msg, e.g. `#{app}.Msg.<Variant>(...)`."

  ## Running

  defp init(run, args) do
    case call(run, run.app <> ".init", args) do
      {:ok, {model, cmd}} ->
        settle(%{run | model: model}, :init, cmd)

      {:ok, _other} ->
        stop(run, :init, "#{run.app}.init returned no (model, cmd)")

      {:error, e} ->
        stop(run, :init, "#{run.app}.init failed: #{error_text(e)}")
    end
  end

  defp send_all(run, []), do: run
  defp send_all(%{stopped?: true} = run, _msgs), do: run

  defp send_all(run, [{source, msg} | rest]) do
    run =
      case update(run, msg) do
        {:ok, model, cmd} -> settle(%{run | model: model}, source, cmd)
        {:error, why} -> stop(run, source, why)
      end

    send_all(run, rest)
  end

  # Runs the step's effects until none are left, or the cap.
  defp settle(run, label, cmd) do
    {queue, entries} =
      case Effects.flatten(cmd) do
        {:ok, effects} -> {effects, []}
        :error -> {[], [failed("(cmd)", "#{run.app} returned a command that is not a Cmd")]}
      end

    {run, entries, error} = drain(run, queue, [], entries, 0)

    step = %{
      msg: label,
      effects: Enum.reverse(entries),
      model: run.model,
      error: error
    }

    %{run | steps: [step | run.steps], stopped?: error != nil}
  end

  # `done`: effects performed in this step, each counted once. `timers`:
  # the step's `Cmd.time.after`s not yet fired, `{due, effect}` by due time
  # (in the order issued for the same one).
  defp drain(run, [], [], entries, _done), do: {run, entries, nil}

  defp drain(run, queue, timers, entries, done) when done >= run.max do
    waiting = queue ++ Enum.map(timers, &elem(&1, 1))
    left = waiting |> Enum.take(@left_shown) |> Enum.map_join(", ", &Effects.describe/1)
    more = length(waiting) - @left_shown
    left = if more > 0, do: "#{left}, … #{more} more", else: left

    {run, entries,
     "step cap reached: #{run.max} effects ran in one step and more were waiting " <>
       "(#{left}). A callback that always issues another effect, or a timer that " <>
       "always re-arms itself, never settles; nothing after this step ran."}
  end

  # Nothing else waits: the earliest timer fires, moving the clock to it.
  defp drain(run, [], [{due, {:after, ms, msg} = effect} | timers], entries, done) do
    entry = %{entry(effect) | value: "fired at #{due}ms", note: "virtual time, after #{ms}ms"}
    deliver(%{run | clock: due}, msg, [], timers, entry, entries, done)
  end

  defp drain(run, [{:after, ms, _msg} = effect | queue], timers, entries, done) do
    due = run.clock + ms
    {before, later} = Enum.split_while(timers, fn {d, _} -> d <= due end)
    drain(run, queue, before ++ [{due, effect} | later], entries, done)
  end

  defp drain(run, [{:wasm, _, _, _, cb} = effect | queue], timers, entries, done) do
    {run, value, note} = wasm(run, effect)
    entry = %{entry(effect) | value: value, note: note}
    called(run, cb, value, entry, queue, timers, entries, done)
  end

  defp drain(run, [effect | queue], timers, entries, done) do
    case perform(run, effect) do
      {:value, value, cb, entry} ->
        called(run, cb, value, entry, queue, timers, entries, done)

      {:done, entry} ->
        drain(run, queue, timers, [entry | entries], done + 1)
    end
  end

  # `cb` applied to `value`, and its msg delivered.
  defp called(run, cb, value, entry, queue, timers, entries, done) do
    case apply_cb(run, cb, value) do
      {:ok, msg} ->
        deliver(run, msg, queue, timers, entry, entries, done)

      {:error, e} ->
        entry = %{entry | error: "its callback failed: #{error_text(e)}"}
        drain(run, queue, timers, [entry | entries], done + 1)
    end
  end

  # A real WASM call, within what is left of the run's WASM time budget
  # (`Nobi.Wasm`'s `:send_budget_ms`); once it is spent, each call left is
  # `Err("timeout")` and runs nothing.
  defp wasm(run, {:wasm, hash, export, input, _cb}) do
    cfg = Nobi.Wasm.config()
    left = Keyword.get(cfg, :send_budget_ms, @wasm_budget_ms) - run.wasm_ms

    if left <= 0 do
      {run, Effects.result({:error, "timeout"}),
       "this send's WASM time budget is spent; nothing ran"}
    else
      t0 = System.monotonic_time(:millisecond)
      answer = Nobi.Wasm.call(hash, export, input, deadline_ms: min(cfg[:deadline_ms], left))
      took = System.monotonic_time(:millisecond) - t0
      {%{run | wasm_ms: run.wasm_ms + took}, Effects.result(answer), nil}
    end
  end

  # `msg` through `update`; its effects join the end of the queue.
  defp deliver(run, msg, queue, timers, entry, entries, done) do
    entry = %{entry | msg: msg}

    case update(run, msg) do
      {:ok, model, cmd} ->
        more =
          case Effects.flatten(cmd) do
            {:ok, effects} -> effects
            :error -> [{:error, "#{run.app} returned a command that is not a Cmd"}]
          end

        drain(%{run | model: model}, queue ++ more, timers, [entry | entries], done + 1)

      {:error, why} ->
        {run, [entry | entries], why}
    end
  end

  # A value for a callback: the entry keeps it.
  defp perform(_run, {:now, cb} = e), do: valued(e, Effects.now(), cb)
  defp perform(_run, {:random, lo, hi, cb} = e), do: valued(e, Enum.random(lo..hi//1), cb)

  defp perform(run, {:navigate, app, args} = e) do
    case Effects.path(run.entries, app, args) do
      {:ok, path} ->
        {:done, %{entry(e) | value: path, note: "a page would go to #{path}; send stays here"}}

      :error ->
        {:done, failed(e, "route table #{run.d.routes} has no route to #{app}")}
    end
  end

  defp perform(run, {:store, op, model, args} = e) do
    case Effects.run_store(run.d.name, run.code, op, model, args) do
      {:ok, value, cb} -> valued(e, value, cb)
      {:error, err} -> {:done, failed(e, error_text(err))}
    end
  end

  defp perform(_run, {:unavailable, name} = e),
    do: {:done, failed(e, "#{name} is not available yet; nothing ran")}

  defp perform(run, {:error, :unknown}),
    do: {:done, failed("(cmd)", "#{run.app} returned an unknown command")}

  defp perform(_run, {:error, message} = e), do: {:done, failed(e, message)}

  defp valued(effect, value, cb), do: {:value, value, cb, %{entry(effect) | value: value}}

  defp entry(effect),
    do: %{effect: Effects.describe(effect), value: nil, error: nil, msg: nil, note: nil}

  defp failed(effect, why) when is_binary(effect),
    do: %{effect: effect, value: nil, error: why, msg: nil, note: nil}

  defp failed(effect, why), do: %{entry(effect) | error: why}

  defp apply_cb(run, cb, value), do: Universe.apply(run.code, cb, [value], [])

  defp update(run, msg) do
    case call(run, run.app <> ".update", [msg, run.model]) do
      {:ok, {model, cmd}} -> {:ok, model, cmd}
      {:ok, _other} -> {:error, "#{run.app}.update returned no (model, cmd)"}
      {:error, e} -> {:error, "#{run.app}.update failed: #{error_text(e)}"}
    end
  end

  defp stop(run, label, why) do
    step = %{msg: label, effects: [], model: run.model, error: why}
    %{run | steps: [step | run.steps], stopped?: true}
  end

  defp call(run, symbol, args) do
    case Universe.call(run.code, symbol, args, []) do
      {:ok, value, _type} -> {:ok, value}
      {:error, _} = error -> error
    end
  end

  defp view(%{model: nil}), do: nil

  defp view(run) do
    case call(run, run.app <> ".view", [run.model]) do
      {:ok, html} -> {:ok, html}
      {:error, e} -> {:error, "#{run.app}.view failed: #{error_text(e)}"}
    end
  end

  @doc "An error as a line of text: `[code] message`, or the message."
  @spec error_text(term()) :: String.t()
  def error_text(%{code: code, message: message}) when is_binary(message),
    do: "[#{code}] #{message}"

  def error_text(message) when is_binary(message), do: message
  def error_text(:no_such_universe), do: "the universe does not exist"
  def error_text(other), do: inspect(other)

  @doc "A value as Nobi source (`Nobi.Exec.show/2`), cut to `max` characters."
  @spec show(term(), pos_integer()) :: String.t()
  def show(value, max) do
    text = Exec.show(value, nil)
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end
end
