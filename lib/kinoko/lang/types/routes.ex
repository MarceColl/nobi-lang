defmodule Kinoko.Lang.Types.Routes do
  @moduledoc """
  Route tables (`defroutes`) and `Cmd.navigate`, checked.

  A route table maps URL patterns to apps. Each target must be a `defapp`,
  and its pattern's parameters must be exactly the target's `init`
  parameters, matched by name, each of a type a URL can carry: `Int`,
  `String` or `Uuid` (`route_param_types/0`). Two patterns that match the
  same URLs are refused: the second could never be reached.

  `Cmd.navigate(App, args…)` is a special form, typed like `App.init(args…)`
  (positional, by type) but of type `Cmd<msg>` for the caller's `msg`.
  Route tables are not consulted: the host resolves the URL in the table
  the serving deployment uses. The call node's `res:` is `{:navigate, app,
  [{param, type}]}` (init's parameters, in order), and the app argument's
  is `{:app, app}`.

  Every signature is read through `Ctx.dget/2`, so a table depends on each
  target and its `init`, and a navigating declaration on `App` and
  `App.init`.
  """

  alias Kinoko.Lang.{Ast, Format}
  alias Kinoko.Lang.Types.{Check, Infer, Quote}
  alias Kinoko.Lang.Types.Check.Ctx

  import Kinoko.Lang.Types.Check.Tree, only: [ty: 1, put_ann: 3]

  @param_types ~w(Int String Uuid)

  @doc "The types a route parameter (and so a routed `init` parameter) may have."
  def route_param_types, do: @param_types

  @doc "Whether `t` is a type a URL parameter can carry."
  def route_param_type?({:named, n}), do: n in @param_types
  def route_param_type?(_), do: false

  # ---------- defroutes ----------

  @doc "A route table's routes, each against its target, then against each other."
  def check_routes(ctx, routes) do
    ctx = Enum.reduce(routes, ctx, &check_route(&2, &1))
    duplicates(ctx, routes)
  end

  defp check_route(ctx, {_segs, app} = route) do
    case Ctx.dget(ctx, app) do
      {:app, ctx} ->
        case Ctx.dget(ctx, "#{app}.init") do
          {{:def, types, _, names}, ctx} -> match_init(ctx, route, Enum.zip(names, types))
          # No init, or not a def: the app's own check says so.
          {_, ctx} -> ctx
        end

      {nil, ctx} ->
        Ctx.error(
          ctx,
          "bad-route",
          "#{shown(route)}: `#{app}` is not defined — a route opens an app; declare it with " <>
            "`defapp #{app}`"
        )

      {sig, ctx} ->
        Ctx.error(
          ctx,
          "bad-route",
          "#{shown(route)}: `#{app}` is #{kind(sig)}, not an app — a route opens a `defapp`, as in " <>
            ~s(`"/post/:id" -> Forum.Post`)
        )
    end
  end

  defp match_init(ctx, {segs, app} = route, params) do
    given = for {:param, n} <- segs, do: n
    wanted = Enum.map(params, &elem(&1, 0))

    ctx =
      if Enum.sort(given) == Enum.sort(wanted) do
        ctx
      else
        fixed =
          Format.route_pattern(
            for({:lit, _} = l <- segs, do: l) ++ Enum.map(wanted, &{:param, &1})
          )

        Ctx.error(
          ctx,
          "route-mismatch",
          "#{shown(route)}: the pattern's parameters must be exactly those of " <>
            "`#{init_text(app, params)}`, by name — write it as #{inspect(fixed)}, or rename " <>
            "init's parameters"
        )
      end

    params
    |> Enum.reject(fn {_, t} -> route_param_type?(t) end)
    |> Enum.reduce(ctx, fn {n, t}, ctx ->
      Ctx.error(
        ctx,
        "route-mismatch",
        "#{shown(route)}: `#{app}.init` parameter `#{n} : #{Quote.type(t)}` cannot come from a " <>
          "URL — a route parameter is Int, String or Uuid"
      )
    end)
  end

  # A later route matching the same URLs as an earlier one: the same
  # length, and at each position two parameters or the same literal.
  defp duplicates(ctx, routes) do
    {ctx, _} =
      Enum.reduce(routes, {ctx, []}, fn {segs, _} = route, {ctx, seen} ->
        shape = shape(segs)

        case List.keyfind(seen, shape, 0) do
          {_, first} ->
            message =
              "#{shown(route)} matches the same URLs as #{shown(first)} above, which always wins — " <>
                "make their literal segments differ, as in \"/post/:id\" and \"/user/:id\""

            {Ctx.error(ctx, "duplicate-route", message), seen}

          nil ->
            {ctx, [{shape, route} | seen]}
        end
      end)

    ctx
  end

  defp shape(segs),
    do:
      Enum.map(segs, fn
        {:param, _} -> :param
        lit -> lit
      end)

  defp shown({segs, app}), do: "route #{inspect(Format.route_pattern(segs))} -> #{app}"

  defp init_text(app, params),
    do: "#{app}.init(#{Enum.map_join(params, ", ", fn {n, t} -> "#{n} : #{Quote.type(t)}" end)})"

  defp kind({:model, _}), do: "a model"
  defp kind({:type, _, _}), do: "a type"
  defp kind({:def, _, _, _}), do: "a def"
  defp kind({:routes, _}), do: "a route table"
  defp kind(:test), do: "a test"
  defp kind(_), do: "not an app"

  # ---------- Cmd.navigate ----------

  @example "`Cmd.navigate(Forum.Post, id)`"

  @doc "`Cmd.navigate(App, args…)`, annotated `Cmd<a>` for a fresh `a`."
  def synth_navigate(ctx, {:call, m, [name, [{:name, _, [app]} = a | args]]} = e) do
    with true <- Ast.capitalised?(app),
         {:app, ctx} <- Ctx.dget(ctx, app),
         {{:def, types, _, names}, ctx} <- Ctx.dget(ctx, "#{app}.init") do
      params = Enum.zip(names, types)

      if length(args) == length(types) do
        {args, ctx} =
          args
          |> Enum.zip(params)
          |> Enum.map_reduce(ctx, fn {arg, param}, ctx ->
            navigate_arg(ctx, e, app, arg, param)
          end)

        {u, ctx} = Ctx.fresh(ctx)
        a = put_ann(a, {:named, "Unit"}, {:app, app})
        {put_ann({:call, m, [name, [a | args]]}, cmd(u), {:navigate, app, params}), ctx}
      else
        message =
          "`#{Quote.expr(e)}` opens `#{app}`, whose `#{init_text(app, params)}` takes " <>
            "#{length(types)} argument(s), got #{length(args)} — write " <>
            "`Cmd.navigate(#{Enum.join([app | names], ", ")})`"

        failed(ctx, e, message)
      end
    else
      false ->
        failed(ctx, e, "`#{Quote.expr(e)}`: `#{app}` is not an app — #{needs()}")

      {nil, ctx} ->
        failed(ctx, e, "`#{Quote.expr(e)}`: `#{app}` is not defined — #{needs()}")

      {:app, ctx} ->
        failed(ctx, e, "`#{Quote.expr(e)}`: `#{app}.init` is not a def — #{needs()}")

      {sig, ctx} ->
        failed(ctx, e, "`#{Quote.expr(e)}`: `#{app}` is #{kind(sig)}, not an app — #{needs()}")
    end
  end

  def synth_navigate(ctx, e),
    do: failed(ctx, e, "`#{Quote.expr(e)}` needs an app first — #{needs()}")

  defp needs, do: "`Cmd.navigate` opens a `defapp` with its init's arguments, as in #{@example}"

  # An argument of exactly its parameter's type; one still open is unified
  # with it.
  defp navigate_arg(ctx, e, app, arg, {n, t}) do
    {s, ctx} = Check.synth(ctx, arg)
    {resolved, ctx} = Ctx.resolve_deep(ctx, ty(s), fn -> Quote.expr(arg) end)

    cond do
      resolved == t ->
        {s, ctx}

      Infer.contains_uvar?(resolved) ->
        {s, Ctx.unify!(ctx, ty(s), t, arg)}

      true ->
        message =
          "`#{Quote.expr(e)}`: argument `#{Quote.expr(arg)}` is #{Ctx.format(ctx, resolved)}, but " <>
            "`#{app}.init` takes `#{n} : #{Quote.type(t)}`"

        {s, Ctx.error(ctx, "bad-navigate", message)}
    end
  end

  defp failed(ctx, e, message) do
    {call, ctx} = ctx |> Ctx.error("bad-navigate", message) |> Check.unchecked(e)
    {call, ctx}
  end

  defp cmd(t), do: {:applied, "Cmd", [t]}
end
