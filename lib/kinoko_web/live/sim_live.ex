defmodule KinokoWeb.SimLive do
  @moduledoc """
  Explorer for `Kinoko.Elm.Sim`: runs a scenario's exhaustive exploration and
  renders the branching tree, with invariant violations and the path to them.
  """

  use KinokoWeb, :live_view
  alias Kinoko.Elm.Sim
  alias Kinoko.Examples.SimScenarios

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        scenarios: SimScenarios.list(),
        scenario: "checkout_racy",
        result: nil,
        took_ms: nil,
        running?: false,
        selected: nil,
        violations_only?: false
      )

    {:ok, if(connected?(socket), do: explore(socket), else: socket)}
  end

  @impl true
  def handle_event("configure", %{"scenario" => key}, socket) do
    if Enum.any?(socket.assigns.scenarios, &(elem(&1, 0) == key)),
      do:
        {:noreply,
         socket
         |> assign(scenario: key, result: nil, selected: nil, violations_only?: false)
         |> explore()},
      else: {:noreply, socket}
  end

  def handle_event("run", _params, socket), do: {:noreply, explore(socket)}

  def handle_event("select", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} when is_map_key(socket.assigns.result.nodes, id) ->
        {:noreply, assign(socket, :selected, id)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_violations", _params, socket),
    do: {:noreply, update(socket, :violations_only?, &(not &1))}

  @impl true
  def handle_async(:explore, {:ok, {key, us, result}}, %{assigns: %{scenario: key}} = socket) do
    {:noreply,
     assign(socket,
       result: result,
       took_ms: div(us, 1000),
       running?: false,
       selected: result.first_violation || result.root
     )}
  end

  # A result for a scenario we already switched away from.
  def handle_async(:explore, {:ok, _stale}, socket), do: {:noreply, socket}

  def handle_async(:explore, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> put_flash(:error, "Exploration crashed: #{inspect(reason)}")}
  end

  defp explore(socket) do
    key = socket.assigns.scenario

    socket
    |> assign(:running?, true)
    |> start_async(:explore, fn ->
      {us, result} = :timer.tc(fn -> Sim.explore(SimScenarios.get(key)) end)
      {key, us, result}
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, visible: visible(assigns), on_path: on_path(assigns))

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <header class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Simulation explorer</h1>
            <p class="mt-1 max-w-xl text-sm text-zinc-500">
              Every interleaving of inputs, timers and effect outcomes, with invariants checked after each step.
            </p>
          </div>
          <.form
            for={to_form(%{"scenario" => @scenario})}
            id="scenario-form"
            phx-change="configure"
            class="flex items-end gap-2"
          >
            <.input
              field={to_form(%{"scenario" => @scenario})[:scenario]}
              type="select"
              label="Scenario"
              options={for {key, title, _} <- @scenarios, do: {title, key}}
            />
            <button
              id="run"
              type="button"
              phx-click="run"
              disabled={@running?}
              class="mb-2 rounded-lg bg-zinc-900 px-4 py-2 text-sm font-medium text-white transition hover:bg-zinc-700 active:scale-95 disabled:opacity-40 dark:bg-zinc-100 dark:text-zinc-900"
            >
              {if @running?, do: "Exploring…", else: "Run again"}
            </button>
          </.form>
        </header>

        <p class="text-sm text-zinc-600 dark:text-zinc-400">
          {Enum.find_value(@scenarios, fn {k, _, d} -> k == @scenario && d end)}
        </p>

        <div :if={is_nil(@result)} class="animate-pulse text-sm text-zinc-500">
          Exploring…
        </div>

        <%= if @result do %>
          <.stats result={@result} took_ms={@took_ms} />

          <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,26rem)]">
            <section class="min-w-0">
              <div class="mb-2 flex items-center justify-between">
                <h2 class="text-sm font-medium text-zinc-500">Exploration tree</h2>
                <button
                  id="toggle-violations"
                  phx-click="toggle_violations"
                  disabled={@result.stats.violations == 0}
                  class={[
                    "rounded-full border px-3 py-1 text-xs transition disabled:opacity-30",
                    if(@violations_only?,
                      do: "border-red-500 bg-red-500/10 text-red-600 dark:text-red-400",
                      else:
                        "border-zinc-300 text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-400 dark:hover:bg-zinc-800"
                    )
                  ]}
                >
                  Violation paths only
                </button>
              </div>
              <ul
                id="sim-tree"
                class="h-[38rem] overflow-auto rounded-2xl border border-zinc-200 p-3 font-mono text-xs dark:border-zinc-800"
              >
                <.tree_node
                  id={@result.root}
                  nodes={@result.nodes}
                  visible={@visible}
                  on_path={@on_path}
                  selected={@selected}
                />
              </ul>
            </section>

            <.details result={@result} id={@selected} />
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :result, :map, required: true
  attr :took_ms, :integer, required: true

  defp stats(assigns) do
    ~H"""
    <div id="sim-stats" class="flex flex-wrap gap-2 text-xs">
      <span class={[chip(), "font-medium"]}>{@result.stats.nodes} nodes · {@took_ms}ms</span>
      <span class={chip()}>depth {@result.stats.max_depth}</span>
      <span :for={{status, n} <- Enum.sort(@result.stats.statuses)} class={chip()}>
        <span class={["inline-block size-2 rounded-full", dot(status)]}></span>
        {n} {status}
      </span>
      <span :if={@result.stats.truncated?} class={[chip(), "text-amber-600"]}>
        truncated at the node limit
      </span>
      <span
        id="sim-verdict"
        class={[
          "rounded-full px-3 py-1 font-medium",
          if(@result.stats.violations > 0,
            do: "bg-red-500/10 text-red-600 dark:text-red-400",
            else: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400"
          )
        ]}
      >
        {if @result.stats.violations > 0,
          do: "#{@result.stats.violations} violating states",
          else: "all invariants hold"}
      </span>
    </div>
    """
  end

  attr :id, :integer, required: true
  attr :nodes, :map, required: true
  attr :visible, :any, required: true
  attr :on_path, :any, required: true
  attr :selected, :integer, required: true

  defp tree_node(assigns) do
    node = assigns.nodes[assigns.id]
    children = Enum.filter(node.children, &(is_nil(assigns.visible) or &1 in assigns.visible))
    assigns = assign(assigns, node: node, children: children)

    ~H"""
    <li>
      <button
        type="button"
        id={"node-#{@id}"}
        phx-click="select"
        phx-value-id={@id}
        class={[
          "flex w-full items-center gap-2 whitespace-nowrap rounded px-1.5 py-0.5 text-left transition hover:bg-zinc-100 dark:hover:bg-zinc-800",
          @id == @selected &&
            "bg-zinc-900 text-white hover:bg-zinc-800 dark:bg-zinc-100 dark:text-zinc-900",
          @id != @selected && @id in @on_path && "font-semibold",
          @id != @selected && @node.status == :duplicate && "text-zinc-400"
        ]}
      >
        <span class={["inline-block size-2 shrink-0 rounded-full", dot(@node.status)]}></span>
        <span>{@node.label}</span>
        <span :if={@node.status == :duplicate} class="opacity-60">≡ #{@node.dup_of}</span>
        <span :if={@node.violations != []} class="text-red-500">
          ✗ {Enum.join(@node.violations, ", ")}
        </span>
      </button>
      <ul :if={@children != []} class="ml-2 border-l border-zinc-200 pl-2 dark:border-zinc-800">
        <.tree_node
          :for={child <- @children}
          id={child}
          nodes={@nodes}
          visible={@visible}
          on_path={@on_path}
          selected={@selected}
        />
      </ul>
    </li>
    """
  end

  attr :result, :map, required: true
  attr :id, :integer, required: true

  defp details(assigns) do
    assigns =
      assign(assigns,
        node: assigns.result.nodes[assigns.id],
        path: Sim.path(assigns.result, assigns.id)
      )

    ~H"""
    <section id="sim-details" class="min-w-0 space-y-5 text-sm">
      <div>
        <h2 class="mb-2 text-sm font-medium text-zinc-500">
          Path to #{@id} <span class="text-zinc-400">· {@node.status}</span>
        </h2>
        <ol class="space-y-0.5 font-mono text-xs">
          <li :for={step <- @path}>
            <button
              type="button"
              phx-click="select"
              phx-value-id={step.id}
              class={[
                "w-full truncate rounded px-1.5 py-0.5 text-left transition hover:bg-zinc-100 dark:hover:bg-zinc-800",
                step.id == @id && "bg-zinc-100 font-semibold dark:bg-zinc-800"
              ]}
            >
              <span class="text-zinc-400">{step.depth}.</span> {step.label}
            </button>
          </li>
        </ol>
      </div>

      <div
        :if={@node.violations != []}
        id="sim-violations"
        class="rounded-xl bg-red-500/10 p-3 text-red-700 dark:text-red-300"
      >
        <p :for={v <- @node.violations}>✗ {v}</p>
      </div>

      <button
        :if={@node.status == :duplicate}
        type="button"
        phx-click="select"
        phx-value-id={@node.dup_of}
        class="text-xs text-zinc-500 underline underline-offset-2"
      >
        Same world as #{@node.dup_of} — explored there
      </button>

      <.facts title="Outputs" items={@node.outputs} empty="No commands this step" />
      <.facts
        title="Pending effects"
        items={Enum.map(@node.pending, &Kinoko.Elm.Timeline.describe(&1.effect))}
        empty="Nothing in flight"
      />

      <div>
        <h3 class="mb-1 text-xs font-medium uppercase tracking-wide text-zinc-500">State</h3>
        <pre class="overflow-auto rounded-xl bg-zinc-950 p-3 text-xs leading-relaxed text-zinc-200">{inspect(@node.state, pretty: true, limit: 40, width: 60)}</pre>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :empty, :string, required: true

  defp facts(assigns) do
    ~H"""
    <div>
      <h3 class="mb-1 text-xs font-medium uppercase tracking-wide text-zinc-500">{@title}</h3>
      <p :if={@items == []} class="text-xs text-zinc-400">{@empty}</p>
      <ul class="space-y-0.5 font-mono text-xs">
        <li :for={item <- @items} class="truncate">{item}</li>
      </ul>
    </div>
    """
  end

  # nil means everything is visible.
  defp visible(%{violations_only?: true, result: %{} = result}) do
    for {id, %{status: status}} <- result.nodes,
        status in [:violation, :crash],
        step <- Sim.path(result, id),
        into: MapSet.new(),
        do: step.id
  end

  defp visible(_assigns), do: nil

  defp on_path(%{result: %{} = result, selected: id}) when is_integer(id),
    do: result |> Sim.path(id) |> MapSet.new(& &1.id)

  defp on_path(_assigns), do: MapSet.new()

  defp chip,
    do:
      "inline-flex items-center gap-1.5 rounded-full border border-zinc-200 px-3 py-1 text-zinc-600 dark:border-zinc-800 dark:text-zinc-400"

  defp dot(status) when status in [:violation, :crash], do: "bg-red-500"
  defp dot(:done), do: "bg-emerald-500"
  defp dot(:stopped), do: "bg-sky-500"
  defp dot(:duplicate), do: "bg-zinc-300 dark:bg-zinc-600"
  defp dot(status) when status in [:depth_limit, :unexplored], do: "bg-amber-400"
  defp dot(_expanded), do: "bg-zinc-500"
end
