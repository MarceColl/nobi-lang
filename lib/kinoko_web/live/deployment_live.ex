defmodule KinokoWeb.DeploymentLive do
  @moduledoc """
  Serves a deployment: the host names a `Kinoko.Deployment`, the path
  picks an app from its route table, and the app's Elm loop runs through
  `Kinoko.Universe` (at the deployment's universe, or the commit it is
  pinned to). Mounted on the router's catch-all, after every reserved
  route; `KinokoWeb.DeploymentStatus` gives the static render its 404.

  ## Steps

  `update/2` is pure. Everything that runs Yabu or reads storage (resolving
  the host, the route table, `init`, `update`, `view`, applying a change
  handler) is a *step*, run off-process as an `Effect.task/2` whose result
  comes back as `{:stepped, seq, result}`: a map of the fields that change.
  One step runs at a time. Msgs that need one (params, events, effect
  callbacks, commits) wait in a FIFO queue and each starts against the
  latest state, so a double click is two updates, never a lost one. A
  result whose `seq` is not the step in flight is dropped. While a step is
  in flight the page shows a thin progress bar and `aria-busy`.

  The view uses `inline_mount: true`: the steps a mount starts run inline,
  so the static render already holds the app's HTML (and the connected
  render starts from it rather than from an empty page).

  ## The loop

    * Params: resolve the host (once), match the path
      (`Kinoko.Lang.Routes.match/2`); a miss is the 404 page. A match runs
      `App.init(args…)`, then `App.view(model)`.
    * Events: every Yabu handler is the LiveView event `"yabu"`
      (`KinokoWeb.YabuHtml`). The handler map of the current render lives
      only here; an event is honoured only when its id is in it *and* the
      handler's kind is the event's (a click id for a click, a submit id
      for a submit, a change id for a change), checked when its step
      starts. Anything else (forged ids, wrong kinds, values that are not
      strings) is ignored and changes nothing. A change handler is a Yabu
      function applied to the input's value with `Kinoko.Universe.apply/4`.
    * `App.update(msg, model)`, then `App.view`. The new model and view
      are kept only if both succeed: an error (runtime, timeout, heap,
      degraded, unavailable, ...) keeps the previous model and view and
      shows a banner. Internal errors show a generic message; their detail
      goes to the log, never to the browser.

  ## Effects

    * `Cmd.none`, `Cmd.batch`: performed here.
    * `Cmd.time.now(cb)` and `Cmd.random.int(lo, hi, cb)`:
      `Kinoko.Elm.Effect.now/1` / `random/2`, whose task applies `cb`
      (unix milliseconds, or the integer) through `Universe.apply/4`. A
      result for an app that has since been replaced is dropped.
    * `Cmd.navigate(App, args…)`: `Kinoko.Lang.Routes.path/3` in the
      deployment's route table, then a `patch` (same LiveView; the new
      path's `handle_params` mounts the target app).
    * Anything else: a notice, "`<effect>` is not available yet".

  ## Live code

  A following deployment subscribes to its universe (an
  `Effect.subscribe/3`, so only the connected process does). Opening
  records the head commit first; once subscribed the head is read again
  and, if it moved, a commit is processed, so a commit landing between the
  first read and the subscription is never missed. On each commit the
  route table is read again and the current path re-matched: the same app
  keeps its model when the signatures of `App.Model` and every model it
  reaches are unchanged (compared from `Universe.symbols/1`, read *before*
  `init` so a racing commit can only cause a needless restart, never a
  stale carry-over), else `init` runs again with the notice "Model
  changed; app restarted"; a path that no longer matches, or a route table
  that is gone, is the 404 page. A 404 or "no routes yet" page tries the
  path again. A pinned deployment never subscribes.

  Time travel (`debug: true`) stays off: its debugger would render inside
  the served app's page, and its snapshots would hold every step's tree
  and handler closures.
  """

  use KinokoWeb.ElmLiveView, params: true, inline_mount: true

  require Logger

  alias Kinoko.{Deployment, Universe}
  alias Kinoko.Elm.Effect, as: Fx
  alias Kinoko.Lang.Routes
  alias KinokoWeb.YabuHtml

  # Param key => handler kind, for the events `YabuHtml` routes by key.
  @simple_events [
    click: "click",
    blur: "blur",
    focus: "focus",
    keydown: "keydown",
    keyup: "keyup"
  ]

  @type_name ~r/[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*/

  # Error codes whose message is meant for the app's author.
  @shown_codes ~w(runtime timeout heap degraded unavailable unloaded no_such_commit host)

  # What a step reads.
  @ctx_keys [:host, :path, :deployment, :target, :entries, :subscribed?, :page] ++
              [:app, :args, :gen, :model, :model_sig]

  @app_fields %{app: nil, args: [], model: nil, model_sig: nil, tree: nil, handlers: %{}}

  @impl KinokoWeb.ElmLiveView
  def init(_params, _session) do
    {Map.merge(@app_fields, %{
       # :loading | :app | :not_found | :no_deployment | :no_routes | :unavailable
       page: :loading,
       host: nil,
       path: "/",
       deployment: nil,
       target: nil,
       entries: [],
       subscribed?: false,
       # The head commit read when the deployment was first opened.
       head: nil,
       # Bumped on each mount of an app; callbacks of older mounts are dropped.
       gen: 0,
       notice: nil,
       error: nil,
       # Steps: the last seq started, the one in flight, and what waits.
       seq: 0,
       inflight: nil,
       queue: []
     }), Fx.none()}
  end

  ## update (pure)

  @impl KinokoWeb.ElmLiveView
  def update({:params, _params, uri}, m) do
    %URI{host: host, path: path} = URI.parse(uri)
    enqueue(%{m | host: host, path: path || "/"}, :open)
  end

  def update({:event, "yabu", params}, m) when is_map(params), do: enqueue(m, {:event, params})

  def update({:event, "dismiss", _params}, m), do: {%{m | notice: nil, error: nil}, Fx.none()}

  def update({:event, _event, _params}, m), do: {m, Fx.none()}

  def update({:yabu_callback, gen, result}, m), do: enqueue(m, {:callback, gen, result})

  def update({:committed, universe, _info}, %{deployment: %{commit: nil, universe: universe}} = m) do
    if :commit in m.queue, do: {m, Fx.none()}, else: enqueue(m, :commit)
  end

  def update(:subscribed, %{deployment: %{universe: u}} = m),
    do: {m, Fx.task(fn -> Universe.head(u) end, &{:head, &1})}

  def update({:head, {:ok, head}}, %{head: seen} = m) when is_integer(head) and head != seen,
    do: update({:committed, m.deployment.universe, %{commit: head}}, %{m | head: head})

  def update({:stepped, seq, result}, %{inflight: seq} = m) do
    {m, fx} = settle(%{m | inflight: nil}, result)
    {m, more} = advance(m)
    {m, [fx, more]}
  end

  def update(_msg, m), do: {m, Fx.none()}

  ## The queue

  defp enqueue(m, item), do: advance(%{m | queue: m.queue ++ [item]})

  defp advance(%{inflight: nil, queue: [item | rest]} = m) do
    case start(%{m | queue: rest}, item) do
      {:step, m, run} ->
        seq = m.seq + 1
        ctx = Map.take(m, @ctx_keys)
        {%{m | seq: seq, inflight: seq}, Fx.task(fn -> run.(ctx) end, &{:stepped, seq, &1})}

      {:skip, m} ->
        advance(m)
    end
  end

  defp advance(m), do: {m, Fx.none()}

  defp start(m, :open), do: {:step, %{m | notice: nil, error: nil}, &run_open/1}

  defp start(m, :commit), do: {:step, m, &run_commit/1}

  defp start(%{page: :app, tree: tree} = m, {:event, params}) when tree != nil do
    m2 = %{m | notice: nil, error: nil}

    case handler_msg(m, params) do
      {:msg, msg} -> {:step, m2, &run_update(&1, msg)}
      {:change, fun, value} -> {:step, m2, &run_change(&1, fun, value)}
      :ignore -> {:skip, m}
    end
  end

  defp start(%{page: :app, gen: gen, tree: tree} = m, {:callback, gen, result})
       when tree != nil do
    case result do
      {:ok, msg} -> {:step, m, &run_update(&1, msg)}
      {:error, e} -> {:skip, fail(m, e)}
    end
  end

  defp start(m, _stale), do: {:skip, m}

  # A step's result: the fields that change, plus the app's `cmd` to lower.
  defp settle(m, {:ok, changes}) do
    {cmd, changes} = Map.pop(changes, :cmd)
    m = Map.merge(m, changes)
    {m, fx} = if cmd, do: lower(m, cmd), else: {m, Fx.none()}
    {m, sub} = subscribe(m)
    {m, [fx, sub]}
  end

  defp settle(m, {:error, reason}) do
    Logger.error("DeploymentLive step crashed: #{inspect(reason)}")
    {fail(m, :crash), Fx.none()}
  end

  # Once, for a following deployment, after its head was read.
  defp subscribe(%{subscribed?: false, head: head, deployment: %{commit: nil, universe: u}} = m)
       when is_integer(head),
       do: {%{m | subscribed?: true}, Fx.subscribe(Kinoko.PubSub, Universe.topic(u), :subscribed)}

  defp subscribe(m), do: {m, Fx.none()}

  ## Events (pure)

  # A change: the id from `_target`, the value a string under `yabu`.
  defp handler_msg(m, %{"_target" => ["yabu", id]} = params) when is_binary(id) do
    with {:change, fun} <- Map.get(m.handlers, id),
         %{^id => value} when is_binary(value) <- params["yabu"] do
      {:change, fun, value}
    else
      _ -> :ignore
    end
  end

  defp handler_msg(_m, %{"_target" => _}), do: :ignore

  defp handler_msg(m, %{"yabu_submit" => id}), do: handler(m, id, :submit)

  defp handler_msg(m, params) do
    case Enum.find(@simple_events, fn {_kind, key} -> Map.has_key?(params, key) end) do
      {kind, key} -> handler(m, params[key], kind)
      nil -> :ignore
    end
  end

  defp handler(m, id, kind) when is_binary(id) do
    case Map.get(m.handlers, id) do
      {^kind, msg} -> {:msg, msg}
      _ -> :ignore
    end
  end

  defp handler(_m, _id, _kind), do: :ignore

  ## Effects (pure)

  defp lower(m, {:cmd, cmd}), do: lower_bare(m, cmd)
  defp lower(m, _other), do: {fail(m, "#{m.app} returned a command that is not a Cmd"), Fx.none()}

  defp lower_bare(m, :none), do: {m, Fx.none()}

  defp lower_bare(m, {:batch, cmds}) when is_list(cmds) do
    {m, fx} = Enum.map_reduce(cmds, m, fn cmd, m -> m |> lower_bare(cmd) |> swap() end)
    {m, Fx.batch(fx)}
  end

  defp lower_bare(m, {:effect, "Cmd.time.now", _, [cb]}),
    do: {m, Fx.now(&callback(m, cb, DateTime.to_unix(&1, :millisecond)))}

  defp lower_bare(m, {:effect, "Cmd.random.int", _, [lo, hi, cb]})
       when is_integer(lo) and is_integer(hi) and lo <= hi,
       do: {m, Fx.random(lo..hi//1, &callback(m, cb, &1))}

  defp lower_bare(m, {:effect, "Cmd.random.int", _, _}),
    do: {fail(m, "Cmd.random.int needs lo ≤ hi"), Fx.none()}

  defp lower_bare(m, {:effect, "Cmd.navigate", _, [app | args]}) when is_binary(app) do
    case navigate_path(m.entries, app, args) do
      {:ok, path} ->
        {m, Fx.patch(path)}

      :error ->
        {fail(m, "Cmd.navigate: route table #{m.deployment.routes} has no route to #{app}"),
         Fx.none()}
    end
  end

  defp lower_bare(m, {:effect, name, _, _}) when is_binary(name),
    do: {%{m | notice: "#{name} is not available yet"}, Fx.none()}

  defp lower_bare(m, _other), do: {fail(m, "#{m.app} returned an unknown command"), Fx.none()}

  defp swap({a, b}), do: {b, a}

  # `Routes.path/3` raises when the args do not fit the route's params.
  defp navigate_path(entries, app, args) do
    Routes.path(entries, app, args)
  rescue
    ArgumentError -> :error
  end

  # Runs in the effect's task: only the target, the mount and the callback
  # are captured, never the model.
  defp callback(%{target: target, gen: gen}, cb, value),
    do: {:yabu_callback, gen, Universe.apply(target, cb, [value], [])}

  ## Steps (run off-process; each returns the fields that change)

  defp run_open(c) do
    case c.deployment || resolve(c.host) do
      nil ->
        Map.merge(@app_fields, %{page: :no_deployment})

      d ->
        # The head is read before any code, so a commit after it is seen
        # once subscribed (`update(:subscribed, _)`).
        head = if d.commit == nil and not c.subscribed?, do: head(d.universe)
        changes = open_path(%{c | deployment: d})
        changes = Map.put(changes, :deployment, d)
        if head, do: Map.put(changes, :head, head), else: changes
    end
  end

  defp run_commit(%{page: :app, model: model} = c) when model != nil do
    case route_table(c) do
      {:ok, c} ->
        case Routes.match(c.entries, c.path) do
          {:ok, app, args} when app == c.app and args == c.args ->
            # Read before re-viewing, like a mount reads it before init.
            if model_sig(c.target, app) == c.model_sig,
              do: c |> view_step(c.model, {:cmd, :none}) |> done(c),
              else: mount(c, app, args, "Model changed; app restarted")

          {:ok, app, args} ->
            mount(c, app, args, nil)

          :not_found ->
            not_found(c)
        end

      {:no_routes, c} ->
        not_found(c)

      {:error, c, e} ->
        done(%{error: describe(e)}, c)
    end
  end

  defp run_commit(%{page: page} = c) when page in [:app, :not_found, :no_routes, :unavailable],
    do: c |> open_path() |> Map.merge(%{notice: nil, error: nil})

  defp run_commit(_c), do: %{}

  defp run_update(c, msg) do
    case call(c, c.app <> ".update", [msg, c.model]) do
      {c, {:ok, {model, cmd}}} ->
        c |> view_step(model, cmd) |> done(c)

      {c, {:ok, _other}} ->
        done(%{error: describe("#{c.app}.update returned no (model, cmd)")}, c)

      {c, {:error, e}} ->
        done(%{error: describe(e)}, c)
    end
  end

  defp run_change(c, fun, value) do
    case yabu(c, &Universe.apply(&1, fun, [value], [])) do
      {c, {:ok, msg}} -> run_update(c, msg)
      {c, {:error, e}} -> done(%{error: describe(e)}, c)
    end
  end

  defp resolve(host) when is_binary(host) do
    case Deployment.resolve(host) do
      {:ok, d} -> d
      :error -> nil
    end
  end

  defp resolve(_host), do: nil

  defp head(universe) do
    case Universe.head(universe) do
      n when is_integer(n) -> n
      _error -> nil
    end
  end

  # Matches the path in the route table and mounts what it names.
  defp open_path(c) do
    with {:ok, c} <- open_target(c),
         {:ok, c} <- route_table(c) do
      case Routes.match(c.entries, c.path) do
        {:ok, app, args} -> mount(c, app, args, nil)
        :not_found -> not_found(c)
      end
    else
      {:no_routes, c} -> done(Map.put(@app_fields, :page, :no_routes), c)
      {:error, c, e} -> done(Map.merge(@app_fields, %{page: :unavailable, error: describe(e)}), c)
    end
  end

  defp open_target(%{target: nil, deployment: d} = c) do
    case Deployment.target(d) do
      {:ok, target} -> {:ok, %{c | target: target}}
      {:error, e} -> {:error, c, e}
    end
  end

  defp open_target(c), do: {:ok, c}

  defp route_table(c) do
    case yabu(c, &Universe.routes/1) do
      {c, tables} when is_map(tables) ->
        case Map.fetch(tables, c.deployment.routes) do
          {:ok, entries} -> {:ok, %{c | entries: entries}}
          :error -> {:no_routes, %{c | entries: []}}
        end

      {c, {:error, e}} ->
        {:error, c, e}
    end
  end

  defp not_found(c), do: done(Map.put(@app_fields, :page, :not_found), c)

  defp mount(c, app, args, notice) do
    # The signature is read BEFORE init: a commit racing this mount can
    # then only make the next commit restart the app needlessly, never
    # carry a model over to a Model it does not fit.
    sig = model_sig(c.target, app)
    c = %{c | app: app, args: args}
    base = Map.merge(@app_fields, %{page: :app, app: app, args: args, gen: c.gen + 1})

    case call(c, app <> ".init", args) do
      {c, {:ok, {model, cmd}}} ->
        case view_step(c, model, cmd) do
          %{tree: _} = changes ->
            done(Map.merge(base, Map.merge(changes, %{model_sig: sig, notice: notice})), c)

          failed ->
            done(Map.merge(base, failed), c)
        end

      {c, {:ok, _other}} ->
        done(Map.put(base, :error, describe("#{app}.init returned no (model, cmd)")), c)

      {c, {:error, e}} ->
        done(Map.put(base, :error, describe(e)), c)
    end
  end

  # Views `model`: the fields that change with it, or only the error (the
  # previous model and view stay).
  defp view_step(c, model, cmd) do
    case call(c, c.app <> ".view", [model]) do
      {_c, {:ok, html}} ->
        {tree, handlers} = YabuHtml.prepare(html)
        %{model: model, tree: tree, handlers: handlers, cmd: cmd, error: nil}

      {_c, {:error, e}} ->
        %{error: describe(e)}
    end
  end

  # Every step reports the target and route table it ended with.
  defp done(changes, c), do: Map.merge(%{target: c.target, entries: c.entries}, changes)

  defp call(c, symbol, args) do
    case yabu(c, &Universe.call(&1, symbol, args, [])) do
      {c, {:ok, value, _type}} -> {c, {:ok, value}}
      {c, {:error, _} = error} -> {c, error}
    end
  end

  # Runs `fun` on the target. A pinned handle whose history was reset
  # under it (`no_such_commit`) is opened again, once.
  defp yabu(c, fun) do
    case fun.(c.target) do
      {:error, %{code: "no_such_commit"}} = error ->
        with %{commit: commit} = d when commit != nil <- c.deployment,
             {:ok, target} <- Deployment.target(d) do
          {%{c | target: target}, fun.(target)}
        else
          _ -> {c, error}
        end

      result ->
        {c, result}
    end
  end

  # The signatures of `App.Model` and of every model it reaches, by name;
  # `nil` (never equal to a computed one) when they cannot be read or the
  # deployment is pinned (it never needs them).
  defp model_sig(universe, app) when is_binary(universe) do
    case Universe.symbols(universe) do
      symbols when is_list(symbols) ->
        sigs = Map.new(symbols, &{&1.symbol, &1.signature})
        models(sigs, [app <> ".Model"], %{})

      _error ->
        nil
    end
  end

  defp model_sig(_pinned, _app), do: nil

  defp models(_sigs, [], acc), do: acc

  defp models(sigs, [name | rest], acc) do
    case sigs do
      %{^name => "model " <> _ = sig} when not is_map_key(acc, name) ->
        refs = @type_name |> Regex.scan(sig) |> List.flatten()
        models(sigs, refs ++ rest, Map.put(acc, name, sig))

      _ ->
        models(sigs, rest, acc)
    end
  end

  ## Errors

  defp fail(m, e), do: %{m | error: describe(e)}

  # What the browser may see: a Yabu error's code and message for the
  # codes meant for the app's author; anything else is logged and shown
  # generically.
  defp describe(%{code: code, message: message} = e) when is_binary(message) do
    if to_string(code) in @shown_codes do
      %{code: to_string(code), message: message}
    else
      internal(e)
    end
  end

  defp describe(message) when is_binary(message), do: %{code: "host", message: message}

  defp describe(:no_such_universe),
    do: %{code: "unavailable", message: "this deployment's universe does not exist"}

  defp describe(other), do: internal(other)

  defp internal(detail) do
    Logger.error("DeploymentLive: #{inspect(detail)}")
    %{code: "internal", message: "Something went wrong on the server."}
  end

  ## view

  @impl KinokoWeb.ElmLiveView
  def view(assigns) do
    ~H"""
    <Layouts.app flash={@flash} bare>
      <div id="deployment" class="min-h-screen" aria-busy={to_string(@model.inflight != nil)}>
        <div
          id="deployment-progress"
          aria-hidden="true"
          class={[
            "pointer-events-none fixed inset-x-0 top-0 z-50 h-0.5 origin-left bg-zinc-900/70 transition-all duration-300 ease-out",
            if(@model.inflight, do: "scale-x-75 opacity-100 delay-150", else: "scale-x-0 opacity-0")
          ]}
        />
        <%= case @model.page do %>
          <% :app -> %>
            <YabuHtml.yabu_html :if={@model.tree} tree={@model.tree} />
          <% :not_found -> %>
            <.page id="deployment-not-found" eyebrow="404" title="Nothing here">
              No route in
              <.code>{@model.deployment.routes}</.code>
              matches <.code>{@model.path}</.code>.
            </.page>
          <% :no_deployment -> %>
            <.page id="no-deployment" eyebrow="Kinoko" title="No deployment for this host">
              Nothing is deployed at <.code>{@model.host || "this host"}</.code>.
              Create a deployment that lists this host, or use <.code>&lt;deployment&gt;.localhost</.code>.
            </.page>
          <% :no_routes -> %>
            <.page id="no-routes" eyebrow={@model.deployment.name} title="No routes yet">
              Universe
              <.code>{@model.deployment.universe}</.code>
              has no route table
              <.code>{@model.deployment.routes}</.code>
              yet. Promote a
              <.code>defroutes {@model.deployment.routes}</.code>
              declaration and this page opens its first route.
            </.page>
          <% :unavailable -> %>
            <.page id="deployment-unavailable" eyebrow={@model.deployment.name} title="Not running">
              This deployment cannot run right now.
            </.page>
          <% :loading -> %>
        <% end %>

        <div class="pointer-events-none fixed inset-x-0 bottom-0 z-50 flex flex-col items-center gap-2 p-4">
          <.banner :if={@model.error} id="deployment-error" tone={:error}>
            <span class="font-mono text-xs uppercase tracking-wide opacity-70">
              {@model.error.code}
            </span>
            <span>{@model.error.message}</span>
          </.banner>
          <.banner :if={@model.notice} id="deployment-notice" tone={:notice}>
            {@model.notice}
          </.banner>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp page(assigns) do
    ~H"""
    <section id={@id} class="flex min-h-screen items-center justify-center bg-zinc-50 px-6">
      <div class="w-full max-w-md rounded-3xl border border-zinc-200 bg-white p-10 shadow-sm">
        <p class="text-xs font-semibold uppercase tracking-[0.2em] text-zinc-400">{@eyebrow}</p>
        <h1 class="mt-3 text-2xl font-semibold tracking-tight text-zinc-900">{@title}</h1>
        <p class="mt-4 text-sm leading-6 text-zinc-600">{render_slot(@inner_block)}</p>
      </div>
    </section>
    """
  end

  slot :inner_block, required: true

  defp code(assigns) do
    ~H"""
    <code class="rounded-md bg-zinc-100 px-1.5 py-0.5 font-mono text-[0.8em] text-zinc-800">
      {render_slot(@inner_block)}
    </code>
    """
  end

  attr :id, :string, required: true
  attr :tone, :atom, values: [:error, :notice]
  slot :inner_block, required: true

  defp banner(assigns) do
    ~H"""
    <div
      id={@id}
      role={if(@tone == :error, do: "alert", else: "status")}
      class={[
        "pointer-events-auto flex w-full max-w-xl items-start gap-3 rounded-2xl px-4 py-3 text-sm shadow-lg ring-1 transition duration-200",
        @tone == :error && "bg-rose-50 text-rose-900 ring-rose-200",
        @tone == :notice && "bg-amber-50 text-amber-900 ring-amber-200"
      ]}
    >
      <.icon
        name={if(@tone == :error, do: "hero-exclamation-triangle", else: "hero-information-circle")}
        class="mt-0.5 size-4 shrink-0"
      />
      <div class="flex flex-1 flex-col gap-0.5">{render_slot(@inner_block)}</div>
      <button
        type="button"
        phx-click="dismiss"
        aria-label="Dismiss"
        class="rounded-md p-0.5 opacity-60 transition hover:opacity-100 active:scale-95"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end
end
