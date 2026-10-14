defmodule Kinoko.Elm.Sim do
  @moduledoc """
  Deterministic simulation testing for Elm-style modules (`Kinoko.ElmGenServer`,
  `KinokoWeb.ElmLiveView`).

  `update/2` is pure and effects are data, so the simulator never runs a process
  or touches the network. It plays the world instead: at every state it lists
  what could happen next and branches on each choice.

    * an environment **input** is sent (each one once, in any interleaving)
    * the oldest pending **dispatch** is delivered (self-sends keep their order)
    * the earliest **timer** fires, advancing a virtual clock
    * any in-flight **async effect** resolves, once per possible outcome
      (http → 200 / 500 / connection refused, random → its bounds, ...)

  Invariants are checked after every step. Commands (`reply`, `send_to`, host
  effects) are recorded as the step's outputs; `stop` ends the branch.

      spec = %{
        module: Kinoko.Examples.Checkout,
        init: fn -> Kinoko.Examples.Checkout.init(stock: 1, strategy: :check_then_pay) end,
        inputs: [Sim.call(:buy, :alice), Sim.call(:buy, :bob)],
        invariants: [{"never oversold", &(&1.stock >= 0)}]
      }

      Sim.explore(spec)            # every interleaving, breadth-first, up to :max_depth
      Sim.check(spec, 1..200)      # seeded random walks; {:error, run} on the first violation

  ## Spec

    * `:module` and `:init` (a 0-arity fun returning `{state, effects}`) — required
    * `:inputs` — msgs the environment sends, each once; `call/2` builds calls
    * `:invariants` — `{name, fun}`; `fun.(state)` or `fun.(state, world)` where
      world is `%{pending: [description], outputs: [description], clock: ms}`
    * `:outcomes` — `fn request, clock -> [{label, result}] | nil` to override
      how async effects can resolve (`nil` falls back to the defaults)
    * `:max_depth` (12), `:max_nodes` (2000)
  """

  alias Kinoko.Elm.Timeline

  @epoch ~U[2026-01-01 00:00:00.000Z]

  @doc "A call msg from `caller`, as `update/2` receives it. Replies show up in outputs."
  def call(request, caller \\ :client), do: {:call, {caller, :sim}, request}

  ## Exhaustive exploration

  @doc """
  Explores every interleaving breadth-first. Returns `%{nodes, root, stats,
  first_violation}`; `nodes` maps id => node, and a node's `:status` is one of
  `:expanded` (has children), `:done` (nothing left to happen), `:violation`, `:crash`, `:stopped`,
  `:duplicate` (same state as `:dup_of`), `:depth_limit` or `:unexplored`.
  """
  def explore(spec) do
    spec = normalize(spec)
    root = root(spec)
    {nodes, truncated?} = bfs(:queue.from_list([0]), %{0 => root}, %{key(root) => 0}, spec)

    nodes =
      Map.new(nodes, fn
        {id, %{status: :open} = node} -> {id, %{node | status: :unexplored}}
        pair -> pair
      end)

    statuses = nodes |> Map.values() |> Enum.frequencies_by(& &1.status)

    violations =
      for {id, %{status: status}} <- nodes, status in [:violation, :crash], do: id

    %{
      nodes: nodes,
      root: 0,
      first_violation: Enum.min(violations, fn -> nil end),
      stats: %{
        nodes: map_size(nodes),
        statuses: statuses,
        violations: length(violations),
        max_depth: nodes |> Map.values() |> Enum.map(& &1.depth) |> Enum.max(),
        truncated?: truncated?
      }
    }
  end

  @doc "Nodes from the root to `id`."
  def path(%{nodes: nodes}, id), do: ancestors(nodes, id, [])

  defp ancestors(_nodes, nil, acc), do: acc
  defp ancestors(nodes, id, acc), do: ancestors(nodes, nodes[id].parent, [nodes[id] | acc])

  defp bfs(queue, nodes, seen, spec) do
    case :queue.out(queue) do
      {:empty, _} ->
        {nodes, false}

      {{:value, id}, queue} ->
        node = nodes[id]

        cond do
          node.status != :open ->
            bfs(queue, nodes, seen, spec)

          node.depth >= spec.max_depth ->
            bfs(queue, Map.put(nodes, id, %{node | status: :depth_limit}), seen, spec)

          true ->
            expand(node, choices(node, spec), queue, nodes, seen, spec)
        end
    end
  end

  defp expand(node, [], queue, nodes, seen, spec),
    do: bfs(queue, Map.put(nodes, node.id, %{node | status: :done}), seen, spec)

  defp expand(node, choices, queue, nodes, seen, spec) do
    if map_size(nodes) + length(choices) > spec.max_nodes do
      {nodes, true}
    else
      {queue, nodes, seen, children} =
        Enum.reduce(choices, {queue, nodes, seen, []}, fn choice, {queue, nodes, seen, kids} ->
          child = step(node, choice, spec, map_size(nodes))

          {child, seen, queue} =
            case child.status == :open && Map.fetch(seen, key(child)) do
              {:ok, original} ->
                {%{child | status: :duplicate, dup_of: original}, seen, queue}

              _ ->
                {child, Map.put(seen, key(child), child.id), :queue.in(child.id, queue)}
            end

          {queue, Map.put(nodes, child.id, child), seen, [child.id | kids]}
        end)

      nodes =
        Map.put(nodes, node.id, %{node | status: :expanded, children: Enum.reverse(children)})

      bfs(queue, nodes, seen, spec)
    end
  end

  # Two nodes are the same world when state, what is still pending (relative to
  # the clock) and the remaining inputs match.
  defp key(node) do
    pending =
      Enum.map(node.pending, fn
        %{kind: :timer, due: due, msg: msg} -> {:timer, due - node.clock, msg}
        %{kind: kind, effect: effect} -> {kind, effect}
      end)

    {node.state, pending, node.inputs}
  end

  ## Random walks

  @doc "One seeded random walk. Returns `%{seed, trace, violation}` (violation is the failing node or nil)."
  def run(spec, seed) do
    spec = normalize(spec)
    walk(root(spec), :rand.seed_s(:exsss, seed), [], spec) |> Map.put(:seed, seed)
  end

  defp walk(node, rand, trace, spec) do
    trace = [node | trace]
    choices = if node.status == :open, do: choices(node, spec), else: []

    cond do
      node.status in [:violation, :crash] ->
        %{trace: Enum.reverse(trace), violation: node}

      choices == [] or node.depth >= spec.max_depth ->
        %{trace: Enum.reverse(trace), violation: nil}

      true ->
        {i, rand} = :rand.uniform_s(length(choices), rand)
        walk(step(node, Enum.at(choices, i - 1), spec, node.id + 1), rand, trace, spec)
    end
  end

  @doc "Random walks for each seed; `{:ok, runs}` or `{:error, run}` for the first violating one."
  def check(spec, seeds) do
    Enum.reduce_while(seeds, {:ok, 0}, fn seed, {:ok, n} ->
      case run(spec, seed) do
        %{violation: nil} -> {:cont, {:ok, n + 1}}
        run -> {:halt, {:error, run}}
      end
    end)
  end

  @doc "A readable trace: one line per step, then the violations."
  def format_trace(nodes) do
    steps = Enum.map(nodes, &"  #{String.pad_leading(to_string(&1.depth), 3)}. #{&1.label}")
    last = List.last(nodes)
    Enum.join(steps ++ Enum.map(last.violations, &"  ✗ #{&1}"), "\n")
  end

  ## Stepping

  defp normalize(spec) do
    spec = Map.new(spec)

    Map.merge(
      %{inputs: [], invariants: [], outcomes: fn _request, _clock -> nil end},
      spec
    )
    |> Map.put_new(:max_depth, 12)
    |> Map.put_new(:max_nodes, 2000)
  end

  defp root(spec) do
    node = %{
      id: 0,
      parent: nil,
      depth: 0,
      label: "init",
      msg: :init,
      state: nil,
      pending: [],
      inputs: spec.inputs,
      clock: 0,
      outputs: [],
      violations: [],
      status: :open,
      dup_of: nil,
      children: [],
      next_effect: 1
    }

    case safely(fn -> spec.init.() end) do
      {:ok, {state, effects}} ->
        %{node | state: state} |> absorb(effects) |> check_invariants(spec)

      {:error, reason} ->
        %{node | status: :crash, violations: ["init crashed: #{reason}"]}
    end
  end

  defp choices(node, spec) do
    inputs =
      node.inputs
      |> Enum.with_index()
      |> Enum.uniq_by(fn {msg, _i} -> msg end)
      |> Enum.map(fn {_msg, i} -> {:input, i} end)

    dispatch =
      node.pending
      |> Enum.filter(&(&1.kind == :dispatch))
      |> Enum.take(1)
      |> Enum.map(&{:take, &1.id})

    timers = Enum.filter(node.pending, &(&1.kind == :timer))
    next_due = timers |> Enum.map(& &1.due) |> Enum.min(fn -> nil end)
    timers = for t <- timers, t.due == next_due, do: {:take, t.id}

    async =
      for %{kind: :async, id: id, request: request} <- node.pending,
          outcome <- outcomes(spec, request, node.clock),
          do: {:resolve, id, outcome}

    inputs ++ dispatch ++ timers ++ async
  end

  defp outcomes(spec, request, clock),
    do: spec.outcomes.(request, clock) || default_outcomes(request, clock)

  @doc "How async requests resolve unless the spec overrides it."
  def default_outcomes({:http, _opts}, _clock) do
    [
      {"200", {:ok, %Req.Response{status: 200, body: ""}}},
      {"500", {:ok, %Req.Response{status: 500, body: ""}}},
      {"refused", {:error, %Req.TransportError{reason: :econnrefused}}}
    ]
  end

  def default_outcomes(:now, clock),
    do: [{"t=#{clock}ms", DateTime.add(@epoch, clock, :millisecond)}]

  def default_outcomes({:random, range}, _clock) do
    values = if Range.size(range) <= 6, do: Enum.to_list(range), else: [range.first, range.last]
    Enum.map(values, &{to_string(&1), &1})
  end

  def default_outcomes({:task, _fun}, _clock), do: [{"error", {:error, :simulated}}]

  defp step(node, choice, spec, id) do
    child = %{
      node
      | id: id,
        parent: node.id,
        depth: node.depth + 1,
        outputs: [],
        violations: [],
        children: [],
        status: :open,
        dup_of: nil
    }

    case safely(fn -> take(child, choice) end) do
      {:ok, {child, msg, label}} ->
        child = %{child | msg: msg, label: label}

        case safely(fn -> spec.module.update(msg, node.state) end) do
          {:ok, {state, effects}} ->
            %{child | state: state} |> absorb(effects) |> check_invariants(spec)

          {:ok, other} ->
            %{child | status: :crash, violations: ["update returned #{inspect(other)}"]}

          {:error, reason} ->
            %{child | status: :crash, violations: ["update crashed: #{reason}"]}
        end

      {:error, reason} ->
        %{
          child
          | label: inspect(choice),
            status: :crash,
            violations: ["to_msg crashed: #{reason}"]
        }
    end
  end

  defp take(node, {:input, i}) do
    {msg, inputs} = List.pop_at(node.inputs, i)
    {%{node | inputs: inputs}, msg, "→ #{short_msg(msg)}"}
  end

  defp take(node, {:take, id}) do
    {entry, node} = pop_pending(node, id)

    case entry do
      %{kind: :dispatch, msg: msg} ->
        {node, msg, "dispatch #{short(msg)}"}

      %{kind: :timer, due: due, msg: msg} ->
        {%{node | clock: max(node.clock, due)}, msg, "⏱ t=#{due}ms #{short(msg)}"}
    end
  end

  defp take(node, {:resolve, id, {outcome, result}}) do
    {%{effect: effect, to_msg: to_msg}, node} = pop_pending(node, id)
    {node, to_msg.(result), "#{Timeline.describe(effect)} ⇒ #{outcome}"}
  end

  defp pop_pending(node, id) do
    {[entry], rest} = Enum.split_with(node.pending, &(&1.id == id))
    {entry, %{node | pending: rest}}
  end

  defp absorb(node, effects) do
    effects
    |> List.wrap()
    |> List.flatten()
    |> Enum.reduce(node, fn effect, node ->
      id = node.next_effect
      node = %{node | next_effect: id + 1}

      case effect do
        {:async, request, to_msg} ->
          entry = %{id: id, kind: :async, effect: effect, request: request, to_msg: to_msg}
          %{node | pending: node.pending ++ [entry]}

        {:send, :self, msg} ->
          %{
            node
            | pending: node.pending ++ [%{id: id, kind: :dispatch, effect: effect, msg: msg}]
          }

        {:after_ms, ms, msg} ->
          entry = %{id: id, kind: :timer, effect: effect, due: node.clock + ms, msg: msg}
          %{node | pending: node.pending ++ [entry]}

        {:stop, _reason} ->
          %{node | outputs: node.outputs ++ [Timeline.describe(effect)], status: :stopped}

        _command ->
          %{node | outputs: node.outputs ++ [Timeline.describe(effect)]}
      end
    end)
  end

  defp check_invariants(%{status: :crash} = node, _spec), do: node

  defp check_invariants(node, spec) do
    world = %{
      pending: Enum.map(node.pending, &Timeline.describe(&1.effect)),
      outputs: node.outputs,
      clock: node.clock
    }

    broken =
      for {name, fun} <- spec.invariants, not holds?(fun, node.state, world), do: name

    if broken == [], do: node, else: %{node | violations: broken, status: :violation}
  end

  defp holds?(fun, state, _world) when is_function(fun, 1),
    do: safely(fn -> fun.(state) end) == {:ok, true}

  defp holds?(fun, state, world), do: safely(fn -> fun.(state, world) end) == {:ok, true}

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason)}
  end

  defp short_msg({:call, {caller, :sim}, request}),
    do: "call #{short(request)} from #{inspect(caller)}"

  defp short_msg(msg), do: short(msg)

  defp short(term) do
    text = inspect(term, limit: 5, printable_limit: 40, width: :infinity)
    if String.length(text) > 70, do: String.slice(text, 0, 67) <> "...", else: text
  end
end
