defmodule KinokoWeb.DeploymentLive do
  @moduledoc """
  Serves a deployment: the request's host names a `Kinoko.Deployment`, the
  path picks an app from its route table, and the app's Elm loop runs
  through `Kinoko.Universe` (at the deployment's universe, or the commit it
  is pinned to). Mounted on the router's catch-all, after every reserved
  route; `KinokoWeb.DeploymentStatus` gives the static render its 404/503
  and resolves the deployment from the request's host into the signed
  session (`"deployment"`, its name). The LiveView only ever serves the
  deployment the session names: the URL the client sends on connect never
  picks one.

  ## Steps

  `update/2` is pure. Everything that runs Yabu or reads storage (reading
  the deployment, the route table, `init`, `update`, `view`, applying a
  change handler) is a *step*, run off-process as an `Effect.task/2` whose
  result comes back as `{:stepped, seq, result}`: a map of the fields that
  change. One step runs at a time. Msgs that need one (params, events,
  effect callbacks, commits, deployment changes) wait in a FIFO queue and
  each starts against the latest state, so a double click is two updates,
  never a lost one. Events and callbacks beyond 32 waiting are dropped.
  A result whose `seq` is not the step in flight is dropped. While a step
  is in flight the page shows a thin progress bar and `aria-busy`.

  A step resolves a following universe's image once
  (`Kinoko.Universe.current/1`), so the route table, `init`, `update` and
  `view` of one step all run on one commit's code with one CodeDb round
  trip.

  The view uses `inline_mount: true`: the steps a mount starts run inline,
  so the static render already holds the app's HTML (and the connected
  render starts from it rather than from an empty page). It keeps no
  timeline (`timeline_limit: 0`): one model per connection, not 200.

  ## The loop

    * Params: read the deployment (once), match the path
      (`Kinoko.Lang.Routes.match/2`); a miss is the 404 page. A match runs
      `App.init(args…)`, then `App.view(model)`.
    * Events: a Yabu handler is the LiveView event `"yabu:<kind>"`
      (`KinokoWeb.YabuHtml`), its id under that kind's key. Each render is
      numbered and its handler ids name it (`r<N>.e<i>`); the handler maps
      of the last 4 renders of the current app and code live only here.
      An event is honoured only when its id is in the render it names
      *and* the handler there is of the event's kind, checked when its
      step starts: a click on a row of a render that has since been
      replaced still means that row. A render that is gone (older, another
      app, code a commit replaced), forged ids, wrong kinds, and values
      that are not strings are ignored and change nothing; so is a submit
      without an id (Enter in a form with no on-submit). A change handler
      is a Yabu function applied to the input's value with
      `Kinoko.Universe.apply/4`.
    * `App.update(msg, model)`, then `App.view`. The new model and view
      are kept only if both succeed: an error (runtime, timeout, heap,
      degraded, unavailable, ...) keeps the previous model and view and
      shows a banner. The banner stays until an event, a new mount or a
      dismiss: an effect callback that succeeds after another failed (two
      effects of one batch) leaves it in place. Internal errors show a generic message; their detail
      goes to the log, never to the browser.

  ## Effects

  A cmd is read by `Kinoko.Deployment.Effects`, the interpreter the MCP
  `send` tool (`Kinoko.Deployment.Runner`) shares, and each effect is
  lowered to a LiveView effect:

    * `Cmd.none`, `Cmd.batch`: performed here.
    * `Cmd.time.now(cb)` and `Cmd.random.int(lo, hi, cb)`:
      `Kinoko.Elm.Effect.now/1` / `random/2`, whose task applies `cb`
      (unix milliseconds, or the integer) through `Universe.apply/4`. A
      result for an app that has since been replaced is dropped.
    * `Cmd.navigate(App, args…)`: `Kinoko.Lang.Routes.path/3` in the
      deployment's route table, then a `patch` (same LiveView; the new
      path's `handle_params` mounts the target app).
    * `Cmd.store.*`: an `Effect.task/2` on the deployment's own data
      (`Kinoko.Data`, its file opened by the deployment's name, whatever
      commit it serves). The models' signatures come from the image that
      issued the effect; `tx` runs through `Kinoko.Data.Tx.run/4`. The
      callback is applied through `Universe.apply/4` and its msg queued
      like any callback (dropped for a replaced mount). A failed operation
      shows the banner (`"store"`, `"unavailable"`, `"too-many-rows"`,
      `"not-found"`) and delivers no msg, except `tx`, whose callback
      receives `Result.Err(message)`. An effect whose model never settled
      (`nil`, from a lone expression) is refused with a banner. While a
      store task runs the page is busy too (progress bar, `aria-busy`):
      its answer arrives as `{:stored, gen, result}`, which ends the wait
      even for a replaced mount, then queues as a callback. A write
      (`insert`, `update`, `delete`, `tx`) runs only in the connected
      mount: the static render runs the mount's reads, `time.now` and
      `random.int` inline (`inline_mount`), so its HTML already holds them,
      but skips its writes, which the connected mount then runs once. So
      the first HTML never reflects init's own writes (nor what a callback
      of one would do): those appear once the page connects.
    * Anything else (`Cmd.blob.*`, `Cmd.ai.*`): a notice, "`<effect>` is
      not available yet".

  ## Live code

  Every open page watches its deployment (`Kinoko.Deployment.topic/1`):
  `pin/2` and `follow/1` re-open the current path on the new code, with a
  notice ("Deployment now serves commit N", "Deployment now follows
  head"), and swap the universe subscription below on or off. The watch
  re-reads the deployment once subscribed, so a pin landing before it is
  never missed.

  A following deployment subscribes to its universe (an
  `Effect.subscribe/3`, so only the connected process does). Opening
  records the head commit first; once subscribed the head is read again
  and, if it moved, a commit is processed, so a commit landing between the
  first read and the subscription is never missed. On each commit the
  route table is read again and the current path re-matched: the same app
  keeps its model when the signatures of `App.Model` and every model it
  reaches are unchanged (compared from `Universe.symbols/1`, read *before*
  the image `init` runs on, so a racing commit can only cause a needless
  restart, never a stale carry-over), else `init` runs again with the
  notice "Model changed; app restarted"; a path that no longer matches, or
  a route table that is gone, is the 404 page. A 404 or "no routes yet"
  page tries the path again. A pinned deployment is not subscribed.

  Time travel (`debug: true`) stays off: its debugger would render inside
  the served app's page, and its snapshots would hold every step's tree
  and handler closures.

  Host element ids all start `kinoko-`; `KinokoWeb.YabuHtml` drops app ids
  in that namespace.
  """

  use KinokoWeb.ElmLiveView, params: true, inline_mount: true, timeline_limit: 0

  require Logger

  alias Kinoko.{Deployment, Universe}
  alias Kinoko.Deployment.Effects
  alias Kinoko.Elm.Effect, as: Fx
  alias Kinoko.Lang.Routes
  alias KinokoWeb.YabuHtml

  # Event kind (the `"yabu:<kind>"` suffix, and the param key holding the
  # id for the simple ones) => handler kind. Fixed atoms.
  @kinds %{
    "click" => :click,
    "blur" => :blur,
    "focus" => :focus,
    "keydown" => :keydown,
    "keyup" => :keyup,
    "submit" => :submit,
    "change" => :change
  }
  @simple [:click, :blur, :focus, :keydown, :keyup]

  # Renders whose handlers stay resolvable, and the waiting events cap.
  @kept_renders 4
  @queue_cap 32

  @type_name ~r/[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*/

  # Error codes whose message is meant for the app's author.
  @shown_codes ~w(runtime timeout heap degraded unavailable unloaded no_such_commit host) ++
                 ~w(store too-many-rows not-found)

  # What a step reads.
  @ctx_keys [:name, :path, :deployment, :target, :entries, :subscribed?, :page, :render] ++
              [:app, :args, :gen, :model, :model_sig]

  @app_fields %{app: nil, args: [], model: nil, model_sig: nil, tree: nil, renders: []}

  @impl KinokoWeb.ElmLiveView
  def init(_params, session) do
    {Map.merge(@app_fields, %{
       # :loading | :app | :not_found | :no_deployment | :no_routes | :unavailable
       page: :loading,
       # From the signed session (`KinokoWeb.DeploymentStatus.session/1`).
       name: string_or_nil(session["deployment"]),
       # True only in the connected mount (`KinokoWeb.ElmLiveView` says so):
       # store writes wait for it, and a session that does not say is not.
       connected?: session["elm_connected?"] == true,
       host: string_or_nil(session["host"]),
       path: "/",
       deployment: nil,
       target: nil,
       entries: [],
       subscribed?: false,
       # The deployment whose topic this page watches.
       watching: nil,
       # The head commit read when the deployment was first opened.
       head: nil,
       # Bumped on each mount of an app; callbacks of older mounts are dropped.
       gen: 0,
       # The last render's number; `renders` holds `{n, handlers}`, newest first.
       render: 0,
       notice: nil,
       error: nil,
       # Steps: the last seq started, the one in flight, and what waits.
       seq: 0,
       inflight: nil,
       # Store tasks started and not yet answered (busy while any run).
       storing: 0,
       queue: :queue.new(),
       queued: 0
     }), Fx.none()}
  end

  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(_), do: nil

  ## update (pure)

  @impl KinokoWeb.ElmLiveView
  def update({:params, _params, uri}, m) do
    %URI{path: path} = URI.parse(uri)
    enqueue(%{m | path: path || "/"}, :open)
  end

  def update({:event, "yabu:" <> kind, params}, m) when is_map(params) do
    case Map.fetch(@kinds, kind) do
      {:ok, kind} -> enqueue(m, {:event, kind, params})
      :error -> {m, Fx.none()}
    end
  end

  def update({:event, "dismiss", _params}, m), do: {%{m | notice: nil, error: nil}, Fx.none()}

  def update({:event, _event, _params}, m), do: {m, Fx.none()}

  def update({:yabu_callback, gen, result}, m), do: enqueue(m, {:callback, gen, result})

  def update({:stored, gen, result}, m),
    do: enqueue(%{m | storing: max(m.storing - 1, 0)}, {:callback, gen, result})

  def update(
        {:committed, universe, _info},
        %{deployment: %{commit: nil, universe: universe}} = m
      ),
      do: enqueue_once(m, :commit)

  def update({:deployment_changed, name}, %{name: name} = m), do: enqueue_once(m, :redeploy)

  def update(:subscribed, %{deployment: %{universe: u}} = m),
    do: {m, Fx.task(fn -> Universe.head(u) end, &{:head, &1})}

  def update({:head, {:ok, head}}, %{head: seen} = m) when is_integer(head) and head != seen,
    do: update({:committed, m.deployment.universe, %{commit: head}}, %{m | head: head})

  def update({:stepped, seq, result}, %{inflight: seq} = m) do
    {m, fx} = settle(%{m | inflight: nil}, result)
    {m, more} = advance(m)
    {m, [fx, more]}
  end

  # An effect callback that raised (`Kinoko.Elm.Runtime`).
  def update({:effect_error, effect, reason}, m),
    do: {fail(m, {:effect_error, effect, reason}), Fx.none()}

  def update(_msg, m), do: {m, Fx.none()}

  ## The queue

  defp enqueue(m, item) do
    if droppable?(item) and m.queued >= @queue_cap,
      do: {m, Fx.none()},
      else: advance(%{m | queue: :queue.in(item, m.queue), queued: m.queued + 1})
  end

  # Control items (open, commit, redeploy) are never dropped: at most one
  # of each waits.
  defp enqueue_once(m, item),
    do: if(:queue.member(item, m.queue), do: {m, Fx.none()}, else: enqueue(m, item))

  defp droppable?({:event, _kind, _params}), do: true
  defp droppable?({:callback, _gen, _result}), do: true
  defp droppable?(_control), do: false

  defp advance(%{inflight: nil} = m) do
    case :queue.out(m.queue) do
      {{:value, item}, rest} ->
        case start(%{m | queue: rest, queued: m.queued - 1}, item) do
          {:step, m, run} ->
            seq = m.seq + 1
            ctx = m |> Map.take(@ctx_keys) |> Map.put(:image, nil)

            {%{m | seq: seq, inflight: seq},
             Fx.task(fn -> ctx |> with_image() |> run.() end, &{:stepped, seq, &1})}

          {:skip, m} ->
            advance(m)
        end

      {:empty, _} ->
        {m, Fx.none()}
    end
  end

  defp advance(m), do: {m, Fx.none()}

  defp start(m, :open), do: {:step, %{m | notice: nil, error: nil}, &run_open/1}

  defp start(m, :commit), do: {:step, m, &run_commit/1}

  defp start(%{deployment: d} = m, :redeploy) when d != nil, do: {:step, m, &run_redeploy/1}

  defp start(%{page: :app, tree: tree} = m, {:event, kind, params}) when tree != nil do
    m2 = %{m | notice: nil, error: nil}

    case handler_msg(m, kind, params) do
      {:msg, msg} -> {:step, m2, &run_update(&1, msg)}
      {:change, fun, value} -> {:step, m2, &run_change(&1, fun, value)}
      :ignore -> {:skip, m}
    end
  end

  defp start(%{page: :app, gen: gen, tree: tree} = m, {:callback, gen, result})
       when tree != nil do
    case result do
      {:ok, msg} -> {:step, m, &keep_error(run_update(&1, msg))}
      {:error, e} -> {:skip, fail(m, e)}
    end
  end

  defp start(m, _stale), do: {:skip, m}

  # A callback that succeeds leaves the banner of one that failed (two
  # effects of one batch) in place; an event or a new mount clears it.
  defp keep_error(%{error: nil} = changes), do: Map.delete(changes, :error)
  defp keep_error(changes), do: changes

  # A step's result: the fields that change, plus the app's `cmd` to lower
  # and the handlers of a new render.
  defp settle(m, {:ok, changes}) do
    {cmd, changes} = Map.pop(changes, :cmd)
    {handlers, changes} = Map.pop(changes, :handlers)
    {origin, changes} = Map.pop(changes, :origin)
    m = m |> Map.merge(changes) |> remember(handlers)
    {m, fx} = if cmd, do: lower(m, cmd, origin), else: {m, Fx.none()}
    {m, watch} = watch(m)
    {m, sub} = subscribe(m)
    {m, [fx, watch, sub]}
  end

  defp settle(m, {:error, reason}) do
    Logger.error("DeploymentLive step crashed: #{inspect(reason)}")
    {fail(m, :crash), Fx.none()}
  end

  defp remember(m, nil), do: m

  defp remember(m, handlers),
    do: %{m | renders: Enum.take([{m.render, handlers} | m.renders], @kept_renders)}

  # Once per deployment: its pin/follow changes. The deployment is read
  # again once subscribed, so a change before the subscription is seen.
  defp watch(%{deployment: %{name: name}, watching: watching} = m) when watching != name do
    {%{m | watching: name},
     Fx.subscribe(Kinoko.PubSub, Deployment.topic(name), {:deployment_changed, name})}
  end

  defp watch(m), do: {m, Fx.none()}

  # A following deployment's universe, after its head was read; dropped
  # when the deployment is pinned.
  defp subscribe(%{subscribed?: false, head: head, deployment: %{commit: nil, universe: u}} = m)
       when is_integer(head),
       do: {%{m | subscribed?: true}, Fx.subscribe(Kinoko.PubSub, Universe.topic(u), :subscribed)}

  defp subscribe(%{subscribed?: true, deployment: %{commit: commit, universe: u}} = m)
       when commit != nil,
       do:
         {%{m | subscribed?: false, head: nil}, Fx.unsubscribe(Kinoko.PubSub, Universe.topic(u))}

  defp subscribe(m), do: {m, Fx.none()}

  ## Events (pure)

  # A change: the id from `_target`, the value a string under `yabu`.
  defp handler_msg(m, :change, %{"_target" => ["yabu", id]} = params) when is_binary(id) do
    with {:change, fun} <- lookup(m, id),
         %{^id => value} when is_binary(value) <- params["yabu"] do
      {:change, fun, value}
    else
      _ -> :ignore
    end
  end

  defp handler_msg(m, :submit, %{"yabu_submit" => id}), do: handler(m, id, :submit)

  defp handler_msg(m, kind, params) when kind in @simple,
    do: handler(m, params[Atom.to_string(kind)], kind)

  defp handler_msg(_m, _kind, _params), do: :ignore

  defp handler(m, id, kind) when is_binary(id) do
    case lookup(m, id) do
      {^kind, msg} -> {:msg, msg}
      _ -> :ignore
    end
  end

  defp handler(_m, _id, _kind), do: :ignore

  # The handler `id` names in the render it names, if that render is kept.
  defp lookup(m, "r" <> rest = id) do
    with [n, _] <- String.split(rest, ".e", parts: 2),
         {n, ""} <- Integer.parse(n),
         {_n, handlers} <- List.keyfind(m.renders, n, 0) do
      Map.get(handlers, id)
    else
      _ -> nil
    end
  end

  defp lookup(_m, _id), do: nil

  ## Effects (pure)

  # The cmd's effects (`Kinoko.Deployment.Effects`, the interpreter the
  # headless runner shares), each lowered to the LiveView effect that
  # performs it. `origin` is the code the cmd came from (the step's image,
  # else its target): store effects read their models' signatures from it.
  defp lower(m, cmd, origin) do
    case Effects.flatten(cmd) do
      {:ok, effects} ->
        {fx, m} =
          Enum.map_reduce(effects, m, fn effect, m ->
            m |> lower_effect(effect, origin) |> swap()
          end)

        {m, Fx.batch(fx)}

      :error ->
        {fail(m, "#{m.app} returned a command that is not a Cmd"), Fx.none()}
    end
  end

  defp lower_effect(m, {:now, cb}, _origin) do
    reply = callback(m, cb)
    {m, Fx.now(&reply.(DateTime.to_unix(&1, :millisecond)))}
  end

  defp lower_effect(m, {:random, lo, hi, cb}, _origin),
    do: {m, Fx.random(lo..hi//1, callback(m, cb))}

  defp lower_effect(m, {:navigate, app, args}, _origin) do
    case Effects.path(m.entries, app, args) do
      {:ok, path} ->
        {m, Fx.patch(path)}

      :error ->
        {fail(m, "Cmd.navigate: route table #{m.deployment.routes} has no route to #{app}"),
         Fx.none()}
    end
  end

  defp lower_effect(m, {:store, op, _model, _args} = effect, origin) do
    cond do
      m.deployment == nil ->
        {fail(m, "Cmd.store.#{op} needs a deployment to store into"), Fx.none()}

      op in Effects.writes() and not m.connected? ->
        {m, Fx.none()}

      true ->
        gen = m.gen

        {%{m | storing: m.storing + 1},
         Fx.task(store(m, origin, effect), fn
           {:ok, msg} -> msg
           {:error, crash} -> {:stored, gen, {:error, {:store_crashed, "Cmd.store.#{op}", crash}}}
         end)}
    end
  end

  defp lower_effect(m, {:unavailable, name}, _origin),
    do: {%{m | notice: "#{name} is not available yet"}, Fx.none()}

  defp lower_effect(m, {:error, :unknown}, _origin),
    do: {fail(m, "#{m.app} returned an unknown command"), Fx.none()}

  defp lower_effect(m, {:error, message}, _origin), do: {fail(m, message), Fx.none()}

  defp swap({a, b}), do: {b, a}

  # The effect's `to_msg`, run in its task. It closes over the target, the
  # mount and the callback only: they are bound here, so the closure never
  # holds the model.
  defp callback(%{target: target, gen: gen}, cb),
    do: fn value -> {:yabu_callback, gen, Universe.apply(target, cb, [value], [])} end

  ## Store effects (run in their task)

  # The effect's task: the operation (`Effects.run_store/5`, on the
  # deployment's data file with the models of the code that issued it),
  # then the callback applied through `Universe.apply/4`. Its msg is a
  # callback result like any effect's, so it waits its turn in the queue
  # and is dropped for a replaced mount. A failed operation delivers
  # `{:error, e}` (the banner) and no msg, except `tx`, whose callback
  # receives `Result.Err(message)`. Like `callback/2`, it closes over the
  # deployment's name, the target, the mount and the effect only, never
  # the model.
  defp store(%{deployment: %{name: name}, target: target, gen: gen}, origin, effect) do
    {:store, op, model, args} = effect

    fn ->
      result =
        with {:ok, value, cb} <- Effects.run_store(name, origin || target, op, model, args),
             do: Universe.apply(target, cb, [value], [])

      {:stored, gen, result}
    end
  end

  ## Steps (run off-process; each returns the fields that change)

  # A following universe's image, resolved once for the whole step.
  defp with_image(%{target: universe} = c) when is_binary(universe) do
    case Universe.current(universe) do
      {:ok, current} -> %{c | image: current}
      _error -> %{c | image: nil}
    end
  end

  defp with_image(c), do: c

  defp run_open(c) do
    case c.deployment || get(c.name) do
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

  # The deployment was pinned or set to follow: the same path, on the new
  # code. Nothing when it serves what this page already does.
  defp run_redeploy(%{deployment: old} = c) do
    case get(old.name) do
      %{commit: commit} when commit == old.commit ->
        %{}

      nil ->
        %{}

      d ->
        head = if d.commit == nil and not c.subscribed?, do: head(d.universe)

        %{c | deployment: d, target: nil, image: nil}
        |> open_path()
        |> Map.merge(%{deployment: d, notice: serves(d)})
        |> then(&if(head, do: Map.put(&1, :head, head), else: &1))
    end
  end

  defp serves(%{commit: nil}), do: "Deployment now follows head"
  defp serves(%{commit: n}), do: "Deployment now serves commit #{n}"

  defp run_commit(%{page: :app, model: model} = c) when model != nil do
    case route_table(c) do
      {:ok, c} ->
        case Routes.match(c.entries, c.path) do
          {:ok, app, args} when app == c.app and args == c.args ->
            # Read before re-viewing, like a mount reads it before init.
            {sig, c} = model_sig(c, app)

            if sig == c.model_sig,
              do: c |> view_step(c.model, {:cmd, :none}) |> fresh() |> done(c),
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

  # A view on new code: the older renders' handlers came from the old
  # code, so they are forgotten.
  defp fresh(%{tree: _} = changes), do: Map.put(changes, :renders, [])
  defp fresh(failed), do: failed

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

  defp get(name) when is_binary(name) do
    case Deployment.get(name) do
      {:ok, d} -> d
      :error -> nil
    end
  end

  defp get(_name), do: nil

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
      {:ok, target} -> {:ok, with_image(%{c | target: target})}
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
    # The signature is read BEFORE the image init runs on: a commit racing
    # this mount can then only make the next commit restart the app
    # needlessly, never carry a model over to a Model it does not fit.
    {sig, c} = model_sig(c, app)
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

  # Views `model`: the fields that change with it (a new render, numbered
  # after the last), or only the error (the previous model and view stay).
  defp view_step(c, model, cmd) do
    case call(c, c.app <> ".view", [model]) do
      {_c, {:ok, html}} ->
        render = c.render + 1
        {tree, handlers} = YabuHtml.prepare(html, render, c.entries)

        %{
          model: model,
          tree: tree,
          handlers: handlers,
          render: render,
          cmd: cmd,
          origin: c.image || c.target,
          error: nil
        }

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

  # Runs `fun` on the step's image (else the target). A pinned handle
  # whose history was reset under it (`no_such_commit`) is opened again,
  # once.
  defp yabu(c, fun) do
    case fun.(c.image || c.target) do
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

  # The signatures of `App.Model` and of every model it reaches, by name,
  # then the step's image resolved again, so the code that runs next is no
  # older than the signatures. `nil` (never equal to a computed one) when
  # they cannot be read or the deployment is pinned (it never needs them).
  defp model_sig(%{target: universe} = c, app) when is_binary(universe) do
    sig =
      case Universe.symbols(universe) do
        symbols when is_list(symbols) ->
          sigs = Map.new(symbols, &{&1.symbol, &1.signature})
          models(sigs, [app <> ".Model"], %{})

        _error ->
          nil
      end

    {sig, with_image(c)}
  end

  defp model_sig(c, _app), do: {nil, c}

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

  @doc "Whether a step or a store task is running (the progress bar, `aria-busy`)."
  def busy?(m), do: m.inflight != nil or m.storing > 0

  ## view

  @impl KinokoWeb.ElmLiveView
  def view(assigns) do
    ~H"""
    <Layouts.app flash={@flash} bare>
      <div id="kinoko-deployment" class="min-h-screen" aria-busy={to_string(busy?(@model))}>
        <div
          id="kinoko-progress"
          aria-hidden="true"
          class={[
            "pointer-events-none fixed inset-x-0 top-0 z-50 h-0.5 origin-left bg-zinc-900/70 transition-all duration-300 ease-out",
            if(busy?(@model),
              do: "scale-x-75 opacity-100 delay-150",
              else: "scale-x-0 opacity-0"
            )
          ]}
        />
        <%= case @model.page do %>
          <% :app -> %>
            <YabuHtml.yabu_html :if={@model.tree} tree={@model.tree} />
          <% :not_found -> %>
            <.page id="kinoko-not-found" eyebrow="404" title="Nothing here">
              No route in
              <.code>{@model.deployment.routes}</.code>
              matches <.code>{@model.path}</.code>.
            </.page>
          <% :no_deployment -> %>
            <.page id="kinoko-no-deployment" eyebrow="Kinoko" title="No deployment for this host">
              Nothing is deployed at <.code>{@model.host || "this host"}</.code>.
              Create a deployment that lists this host, or use <.code>&lt;deployment&gt;.localhost</.code>.
            </.page>
          <% :no_routes -> %>
            <.page id="kinoko-no-routes" eyebrow={@model.deployment.name} title="No routes yet">
              Universe
              <.code>{@model.deployment.universe}</.code>
              has no route table
              <.code>{@model.deployment.routes}</.code>
              yet. Promote a
              <.code>defroutes {@model.deployment.routes}</.code>
              declaration and this page opens its first route.
            </.page>
          <% :unavailable -> %>
            <.page id="kinoko-unavailable" eyebrow={@model.deployment.name} title="Not running">
              This deployment cannot run right now.
            </.page>
          <% :loading -> %>
        <% end %>

        <div class="pointer-events-none fixed inset-x-0 bottom-0 z-50 flex flex-col items-center gap-2 p-4">
          <.banner :if={@model.error} id="kinoko-error" tone={:error}>
            <span class="font-mono text-xs uppercase tracking-wide opacity-70">
              {@model.error.code}
            </span>
            <span>{@model.error.message}</span>
          </.banner>
          <.banner :if={@model.notice} id="kinoko-notice" tone={:notice}>
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
