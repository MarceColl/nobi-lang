defmodule KinokoWeb.DeploymentLive do
  @moduledoc """
  Serves a deployment: the host names a `Kinoko.Deployment`, the path
  picks an app from its route table, and the app's Elm loop runs here
  through `Kinoko.Universe` (at the deployment's universe, or the commit
  it is pinned to). Mounted on the router's catch-all, after every
  reserved route.

  ## The loop

    * `handle_params` resolves the host (once), then the path
      (`Kinoko.Lang.Routes.match/2`); a miss is the 404 page. A match runs
      `App.init(args…)`, then `App.view(model)`.
    * Events: every Yabu handler is the LiveView event `"yabu"`
      (`KinokoWeb.YabuHtml`). The handler map of the current render lives
      only here; an event is honoured only when its id is in it *and* the
      handler's kind is the event's (a click id for a click, a submit id
      for a submit, a change id for a change). Anything else (forged ids,
      wrong kinds, values that are not strings) is ignored. A change
      handler is a Yabu function: it is applied to the input's value with
      `Kinoko.Universe.apply/4`, never called here.
    * `App.update(msg, model)`, then `App.view`. The new model and view
      are kept only if both succeed: an error (runtime, timeout, heap,
      degraded, unavailable, ...) keeps the previous model and view and
      shows a banner.

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

  A following deployment subscribes to its universe (connected mount
  only). On each commit the route table is read again and the current
  path re-matched: the same app keeps its model when the signatures of
  `App.Model` and every model it reaches are unchanged (compared from
  `Universe.symbols/1`), else `init` runs again with the notice "Model
  changed; app restarted"; a path that no longer matches, or a route
  table that is gone, is the 404 page. A 404 or "no routes yet" page
  tries the path again. A pinned deployment never subscribes.
  """

  use KinokoWeb.ElmLiveView, params: true

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

  @impl KinokoWeb.ElmLiveView
  def init(_params, _session) do
    {%{
       # :loading | :app | :not_found | :no_deployment | :no_routes | :unavailable
       page: :loading,
       host: nil,
       path: "/",
       deployment: nil,
       target: nil,
       entries: [],
       subscribed?: false,
       app: nil,
       args: [],
       # Bumped on each mount of an app; callbacks of older mounts are dropped.
       gen: 0,
       model: nil,
       model_sig: nil,
       tree: nil,
       handlers: %{},
       notice: nil,
       error: nil
     }, Fx.none()}
  end

  ## update

  @impl KinokoWeb.ElmLiveView
  def update({:params, _params, uri}, m) do
    %URI{host: host, path: path} = URI.parse(uri)
    m = %{m | host: host, path: path || "/", notice: nil, error: nil}

    case m.deployment || resolve(host) do
      nil ->
        {%{clear_app(m) | page: :no_deployment}, Fx.none()}

      d ->
        {m, fx} = open_path(%{m | deployment: d})
        subscribe(m, fx)
    end
  end

  def update({:event, "yabu", params}, %{page: :app, tree: tree} = m)
      when is_map(params) and tree != nil do
    case handler_msg(m, params) do
      {:ok, m, msg} -> run_update(%{m | notice: nil, error: nil}, msg)
      {:error, m, e} -> {fail(m, e), Fx.none()}
      :ignore -> {m, Fx.none()}
    end
  end

  def update({:event, "dismiss", _params}, m), do: {%{m | notice: nil, error: nil}, Fx.none()}

  def update({:event, _event, _params}, m), do: {m, Fx.none()}

  def update({:yabu_callback, gen, result}, %{gen: gen, page: :app, tree: tree} = m)
      when tree != nil do
    case result do
      {:ok, msg} -> run_update(m, msg)
      {:error, e} -> {fail(m, e), Fx.none()}
    end
  end

  def update({:yabu_callback, _gen, _result}, m), do: {m, Fx.none()}

  def update({:subscribe, universe}, m) do
    _ = Universe.subscribe(universe)
    {m, Fx.none()}
  end

  def update(
        {:committed, universe, _info},
        %{deployment: %{commit: nil, universe: universe}} = m
      ),
      do: on_commit(m)

  def update(_msg, m), do: {m, Fx.none()}

  ## Resolving

  defp resolve(host) when is_binary(host) do
    case Deployment.resolve(host) do
      {:ok, d} -> d
      :error -> nil
    end
  end

  defp resolve(_host), do: nil

  # Matches the path in the route table and mounts what it names.
  defp open_path(m) do
    with {:ok, m} <- open_target(m),
         {:ok, m} <- route_table(m) do
      case Routes.match(m.entries, m.path) do
        {:ok, app, args} -> mount_app(m, app, args, nil)
        :not_found -> {%{clear_app(m) | page: :not_found}, Fx.none()}
      end
    else
      {:no_routes, m} -> {%{clear_app(m) | page: :no_routes}, Fx.none()}
      {:error, m, e} -> {fail(%{clear_app(m) | page: :unavailable}, e), Fx.none()}
    end
  end

  defp open_target(%{target: nil, deployment: d} = m) do
    case Deployment.target(d) do
      {:ok, target} -> {:ok, %{m | target: target}}
      {:error, e} -> {:error, m, e}
    end
  end

  defp open_target(m), do: {:ok, m}

  defp route_table(m) do
    case yabu(m, &Universe.routes/1) do
      {m, tables} when is_map(tables) ->
        case Map.fetch(tables, m.deployment.routes) do
          {:ok, entries} -> {:ok, %{m | entries: entries}}
          :error -> {:no_routes, %{m | entries: []}}
        end

      {m, {:error, e}} ->
        {:error, m, e}
    end
  end

  # Once, for a following deployment; a dispatch is performed only by the
  # connected process, so the static render never subscribes.
  defp subscribe(%{subscribed?: false, deployment: %{commit: nil, universe: u}} = m, fx),
    do: {%{m | subscribed?: true}, [fx, Fx.dispatch({:subscribe, u})]}

  defp subscribe(m, fx), do: {m, fx}

  ## The app loop

  defp mount_app(m, app, args, notice) do
    m = %{clear_app(m) | page: :app, app: app, args: args, gen: m.gen + 1, notice: notice}

    case call(m, app <> ".init", args) do
      {m, {:ok, {model, cmd}}} -> settle(%{m | model_sig: model_sig(m)}, model, cmd)
      {m, {:ok, _other}} -> {fail(m, "#{app}.init did not return (model, cmd)"), Fx.none()}
      {m, {:error, e}} -> {fail(m, e), Fx.none()}
    end
  end

  defp run_update(m, msg) do
    case call(m, m.app <> ".update", [msg, m.model]) do
      {m, {:ok, {model, cmd}}} -> settle(m, model, cmd)
      {m, {:ok, _other}} -> {fail(m, "#{m.app}.update did not return (model, cmd)"), Fx.none()}
      {m, {:error, e}} -> {fail(m, e), Fx.none()}
    end
  end

  # Views `model`; only when that succeeds do the model and view change and
  # `cmd` run.
  defp settle(m, model, cmd) do
    case call(m, m.app <> ".view", [model]) do
      {m, {:ok, html}} ->
        {tree, handlers} = YabuHtml.prepare(html)
        lower(%{m | model: model, tree: tree, handlers: handlers}, cmd)

      {m, {:error, e}} ->
        {fail(m, e), Fx.none()}
    end
  end

  defp call(m, symbol, args) do
    case yabu(m, &Universe.call(&1, symbol, args, [])) do
      {m, {:ok, value, _type}} -> {m, {:ok, value}}
      {m, {:error, _} = error} -> {m, error}
    end
  end

  # Runs `fun` on the target. A pinned handle whose history was reset
  # under it (`no_such_commit`) is opened again, once.
  defp yabu(m, fun) do
    case fun.(m.target) do
      {:error, %{code: "no_such_commit"}} = error ->
        with %{commit: c} = d when c != nil <- m.deployment,
             {:ok, target} <- Deployment.target(d) do
          {%{m | target: target}, fun.(target)}
        else
          _ -> {m, error}
        end

      result ->
        {m, result}
    end
  end

  ## Events

  # A change: the id from `_target`, the value a string under `yabu`.
  defp handler_msg(m, %{"_target" => ["yabu", id]} = params) when is_binary(id) do
    with {:change, fun} <- Map.get(m.handlers, id),
         %{^id => value} when is_binary(value) <- params["yabu"] do
      case yabu(m, &Universe.apply(&1, fun, [value], [])) do
        {m, {:ok, msg}} -> {:ok, m, msg}
        {m, {:error, e}} -> {:error, m, e}
      end
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
      {^kind, msg} -> {:ok, m, msg}
      _ -> :ignore
    end
  end

  defp handler(_m, _id, _kind), do: :ignore

  ## Effects

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

  defp lower_bare(m, {:effect, "Cmd.random.int", _, [lo, hi, _cb]}),
    do: {fail(m, "Cmd.random.int: the range #{inspect(lo)}..#{inspect(hi)} is empty"), Fx.none()}

  defp lower_bare(m, {:effect, "Cmd.navigate", _, [app | args]}) when is_binary(app) do
    case navigate_path(m, app, args) do
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
  defp navigate_path(m, app, args) do
    Routes.path(m.entries, app, args)
  rescue
    ArgumentError -> :error
  end

  # Runs in the effect's task: only the target, the mount and the callback
  # are captured, never the model.
  defp callback(%{target: target, gen: gen}, cb, value),
    do: {:yabu_callback, gen, Universe.apply(target, cb, [value], [])}

  ## Live code

  defp on_commit(%{page: :app, model: model} = m) when model != nil do
    with {:ok, m} <- route_table(m) do
      case Routes.match(m.entries, m.path) do
        {:ok, app, args} when app == m.app and args == m.args ->
          if model_sig(m) == m.model_sig,
            do: settle(m, m.model, {:cmd, :none}),
            else: mount_app(m, app, args, "Model changed; app restarted")

        {:ok, app, args} ->
          mount_app(m, app, args, nil)

        :not_found ->
          {%{clear_app(m) | page: :not_found}, Fx.none()}
      end
    else
      {:no_routes, m} -> {%{clear_app(m) | page: :not_found}, Fx.none()}
      {:error, m, e} -> {fail(m, e), Fx.none()}
    end
  end

  defp on_commit(%{page: page} = m) when page in [:app, :not_found, :no_routes, :unavailable],
    do: open_path(%{m | notice: nil, error: nil})

  defp on_commit(m), do: {m, Fx.none()}

  # The signatures of `App.Model` and of every model it reaches, by name;
  # `nil` (never equal to a computed one) when they cannot be read or the
  # deployment is pinned (it never needs them).
  defp model_sig(%{target: universe, app: app}) when is_binary(universe) do
    case Universe.symbols(universe) do
      symbols when is_list(symbols) ->
        sigs = Map.new(symbols, &{&1.symbol, &1.signature})
        models(sigs, [app <> ".Model"], %{})

      _error ->
        nil
    end
  end

  defp model_sig(_m), do: nil

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

  ## Helpers

  defp clear_app(m),
    do: %{m | app: nil, args: [], model: nil, model_sig: nil, tree: nil, handlers: %{}}

  defp fail(m, e), do: %{m | error: describe(e)}

  defp describe(%{code: code, message: message}) when is_binary(message),
    do: %{code: to_string(code), message: message}

  defp describe(message) when is_binary(message), do: %{code: "host", message: message}

  defp describe(:no_such_universe),
    do: %{code: "unavailable", message: "this deployment's universe does not exist"}

  defp describe(other), do: %{code: "internal", message: inspect(other)}

  ## view

  @impl KinokoWeb.ElmLiveView
  def view(assigns) do
    ~H"""
    <Layouts.app flash={@flash} bare>
      <div id="deployment" class="min-h-screen">
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
