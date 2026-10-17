defmodule Kinoko.Lang.Types.JsxApp do
  @moduledoc """
  JSX checking (an element's attributes and children) and `defapp`'s shape
  (ported from `types/check/jsx_app.rs`, TS's `synthJsx`/`checkApp`).

  An element is an `Html<m>`, where `m` is the type of the messages its
  events send. Its children send the same. With no event anywhere in it,
  `m` is left to its context. TS's `Html` takes no parameter; this is Rust's.
  """

  alias Kinoko.Lang.Types.{Check, Patterns, Quote, Routes}
  alias Kinoko.Lang.Types.Check.Ctx

  import Kinoko.Lang.Types.Check.Tree, only: [ty: 1, res: 1, put_ann: 3]

  # The events the renderer (`KinokoWeb.YabuHtml`) wires, and the tags it
  # wires each on (`:any` for every tag). `change` takes a String
  # constructor; every other event a message value.
  @events %{
    "click" => :any,
    "blur" => :any,
    "focus" => :any,
    "keydown" => :any,
    "keyup" => :any,
    "submit" => ["form"],
    "change" => ["input", "textarea", "select"]
  }

  @doc """
  The JSX events, `%{event => :any | [tag]}`: the only `on-<event>`
  attributes that check, each only on its tags. `KinokoWeb.YabuHtml`
  wires exactly these (a test holds the two together).
  """
  @spec events() :: %{String.t() => :any | [String.t()]}
  def events, do: @events

  @doc "`Html<sends>`: what sends messages of type `sends`."
  def html(sends), do: {:applied, "Html", [sends]}

  @doc """
  An element, annotated `Html<m>`: each attribute and child checked for
  what it may hold, nested elements alike. A nested element is no
  expression and carries no annotation. Returns `{typed, ctx}`.
  """
  def synth_jsx(ctx, {:jsx, _, _} = e) do
    {typed, sends, ctx} = element(ctx, e, false)
    {put_ann(typed, html(sends), nil), ctx}
  end

  # `in_form?`: an ancestor in this JSX is a <form>. The renderer turns a
  # form nested in another into a <div> and drops its on-submit.
  defp element(ctx, {:jsx, m, [tag, attrs, children]}, in_form?) do
    {sends, ctx} = Ctx.fresh(ctx)
    {attrs, ctx} = Enum.map_reduce(attrs, ctx, &attr(&2, &1, {tag, in_form?}, sends))
    nested? = in_form? or tag == "form"
    {children, ctx} = Enum.map_reduce(children, ctx, &child(&2, &1, nested?, sends))
    {{:jsx, m, [tag, attrs, children]}, sends, ctx}
  end

  defp attr(ctx, {:text, _, _} = a, _tag, _sends), do: {a, ctx}

  defp attr(ctx, {:event, event, x}, {tag, in_form?}, sends) do
    {s, ctx} = Check.synth(ctx, x)

    ctx =
      cond do
        not Map.has_key?(@events, event) ->
          Ctx.error(ctx, "bad-event", unknown_event(event, x))

        @events[event] != :any and tag not in @events[event] ->
          Ctx.error(ctx, "bad-event", wrong_tag(event, tag))

        event == "submit" and in_form? ->
          message =
            "on-submit on a <form> inside another <form> is never sent: the inner form " <>
              "renders as a <div>; put on-submit on the outer form"

          Ctx.error(ctx, "bad-event", message)

        event == "change" ->
          check_change_handler(ctx, x, s, sends)

        true ->
          check_message(ctx, event, x, s, sends)
      end

    {{:event, event, s}, ctx}
  end

  defp attr(ctx, {:expr, name, x}, _tag, _sends) do
    {s, ctx} = Check.synth(ctx, x)
    {resolved, ctx} = Ctx.resolve_deep(ctx, ty(s), fn -> Quote.expr(x) end)

    ctx =
      case resolved do
        {:named, "Href"} when name == "href" ->
          ctx

        {:named, "Href"} ->
          message =
            "attribute `#{name}` cannot hold a link: `Html.href(...)` goes in an `href`, as " <>
              "in `<a href={#{Quote.expr(x)}}>`"

          Ctx.error(ctx, "mismatch", message)

        {:named, n} ->
          if n in Patterns.scalars(), do: ctx, else: not_scalar(ctx, name, x, s)

        _ ->
          not_scalar(ctx, name, x, s)
      end

    {{:expr, name, s}, ctx}
  end

  defp unknown_event("input", x) do
    "on-input is not an event Kinoko wires: text comes in through on-change; use " <>
      "on-change={#{Quote.expr(x)}} with an unapplied constructor of one String, which is " <>
      "sent with the text on every edit"
  end

  defp unknown_event(event, _x) do
    "on-#{event} is not an event Kinoko wires; the events are on-click, on-blur, on-focus, " <>
      "on-keydown, on-keyup (a message value), on-submit (on a <form>, a message value) and " <>
      "on-change (on an input, textarea or select, an unapplied String constructor)"
  end

  defp wrong_tag("submit", tag), do: "on-submit works only on a <form>, not a <#{tag}>"

  defp wrong_tag("change", tag),
    do: "on-change works only on an input, textarea or select, not a <#{tag}>"

  defp not_scalar(ctx, name, x, s) do
    shown = Ctx.format(ctx, ty(s))
    message = "attribute `#{name}` must be a scalar, got #{shown} in `#{Quote.expr(x)}`"
    Ctx.error(ctx, "mismatch", message)
  end

  defp child(ctx, {:text, _} = c, _in_form?, _sends), do: {c, ctx}

  defp child(ctx, {:expr, x}, _in_form?, sends) do
    {s, ctx} = synth_child(ctx, x, sends)
    {{:expr, s}, ctx}
  end

  defp child(ctx, {:element, inner}, in_form?, sends) do
    {typed, inner_sends, ctx} = element(ctx, inner, in_form?)
    {_, ctx} = Ctx.unify_quoting(ctx, html(inner_sends), html(sends), fn -> Quote.expr(inner) end)
    {{:element, typed}, ctx}
  end

  # `on-change={handler}`: the handler is applied to the input's text when
  # it changes, so it must be a constructor left unapplied, of one `String`
  # argument. A function of that type is not enough: only a constructor is
  # data the runtime applies. What it builds is the message the element
  # sends. Its argument is checked whatever the handler is, as in TS.
  defp check_change_handler(ctx, x, s, sends) do
    ctor_of_one = match?({:ctor_ref, _, _, 1}, res(s))
    {resolved, ctx} = Ctx.resolve_deep(ctx, ty(s), fn -> Quote.expr(x) end)

    {builds, ctx} =
      case resolved do
        {:arrow, [param], ret} ->
          {ok, ctx} = Ctx.unify(ctx, param, {:named, "String"}, x)
          {if(ok, do: ret), ctx}

        _ ->
          {nil, ctx}
      end

    if builds != nil and ctor_of_one do
      Ctx.unify!(ctx, builds, sends, x)
    else
      message =
        "on-change needs an unapplied 1-argument String constructor, got `#{Quote.expr(x)}`"

      Ctx.error(ctx, "bad-event", message)
    end
  end

  # `on-{event}={handler}` for any other event: the handler is the message
  # sent, a value of a deftype, of the type the element sends. Its type is a
  # dependency, whatever it is.
  defp check_message(ctx, event, x, s, sends) do
    {resolved, ctx} = Ctx.resolve_deep(ctx, ty(s), fn -> Quote.expr(x) end)

    {message?, ctx} =
      case resolved do
        {:named, n} -> deftype?(ctx, n)
        {:applied, n, _} -> deftype?(ctx, n)
        _ -> {false, ctx}
      end

    if message? do
      Ctx.unify!(ctx, ty(s), sends, x)
    else
      shown = Ctx.format(ctx, ty(s))

      message =
        "on-#{event} needs a message value (a variant), got #{shown} in `#{Quote.expr(x)}`"

      Ctx.error(ctx, "bad-event", message)
    end
  end

  defp deftype?(ctx, name) do
    {sig, ctx} = Ctx.dget(ctx, name)
    {match?({:type, _, _}, sig), ctx}
  end

  # `{x}` inside an element: an `Html`, a `String`, an `Int` or a
  # `List<Html>`, the `Html` sending what the element sends. A type still
  # open is taken to be that `Html`.
  defp synth_child(ctx, x, sends) do
    {s, ctx} = Check.synth(ctx, x)
    drawn = html(sends)
    {resolved, ctx} = Ctx.resolve_deep(ctx, ty(s), fn -> Quote.expr(x) end)

    {ok, ctx} =
      case resolved do
        {:named, n} ->
          {n in ["String", "Int"], ctx}

        # A mismatch of what is sent is reported as one; the child is of a
        # kind an element holds all the same.
        {:applied, "Html", _} ->
          {true, Ctx.unify!(ctx, ty(s), drawn, x)}

        {:applied, "List", [{:applied, "Html", _}]} ->
          {true, Ctx.unify!(ctx, ty(s), {:applied, "List", [drawn]}, x)}

        {:uvar, _} = open ->
          Ctx.unify(ctx, open, drawn, x)

        _ ->
          {false, ctx}
      end

    ctx =
      if ok do
        ctx
      else
        shown = Ctx.format(ctx, ty(s))

        message =
          "JSX child must be Html, String, Int, or List<Html>, got #{shown} in `#{Quote.expr(x)}`"

        Ctx.error(ctx, "mismatch", message)
      end

    {s, ctx}
  end

  # ---------- an app's shape ----------

  @doc """
  `defapp App` (TS's `checkApp`): `App.Model` a model, `App.Msg` a type,
  and `App.init`, `App.update` and `App.view` defs of exactly the types the
  runtime calls them at. `init` may take Int, String or Uuid parameters,
  which a route fills from the URL. Every part is looked up as a dependency, a missing
  one too.
  """
  def check_app(ctx, app) do
    {model, ctx} = app_part(ctx, app, "Model")
    {msg, ctx} = app_part(ctx, app, "Msg")
    {init, ctx} = app_part(ctx, app, "init")
    {update, ctx} = app_part(ctx, app, "update")
    {view, ctx} = app_part(ctx, app, "view")

    ctx =
      if model != nil and not match?({:model, _}, model),
        do: Ctx.error(ctx, "bad-app-shape", "`#{app}.Model` must be a defmodel"),
        else: ctx

    ctx =
      if msg != nil and not match?({:type, _, _}, msg),
        do: Ctx.error(ctx, "bad-app-shape", "`#{app}.Msg` must be a deftype"),
        else: ctx

    model_t = {:named, "#{app}.Model"}
    msg_t = {:named, "#{app}.Msg"}
    step = {:tuple, [model_t, {:applied, "Cmd", [msg_t]}]}

    ctx
    |> app_init(init, "#{app}.init", step)
    |> app_def(update, "#{app}.update", {:arrow, [msg_t, model_t], step})
    |> app_def(view, "#{app}.view", {:arrow, [model_t], html(msg_t)})
  end

  # `{app}.{part}`'s signature, reported when there is none.
  defp app_part(ctx, app, part) do
    case Ctx.dget(ctx, "#{app}.#{part}") do
      {nil, ctx} ->
        message = "app `#{app}` requires `#{app}.#{part}`, which is not defined"
        {nil, Ctx.error(ctx, "bad-app-shape", message)}

      found ->
        found
    end
  end

  # `init` may take parameters, each of a type a route fills from a URL
  # (`Kinoko.Lang.Types.Routes.route_param_types/0`); it returns `step`.
  defp app_init(ctx, {:def, params, _, names} = init, name, step) do
    ctx = app_def(ctx, init, name, {:arrow, params, step})

    names
    |> Enum.zip(params)
    |> Enum.reject(fn {_, t} -> Routes.route_param_type?(t) end)
    |> Enum.reduce(ctx, fn {n, t}, ctx ->
      message =
        "`#{name}` parameter `#{n} : #{Quote.type(t)}` — init takes only Int, String or Uuid " <>
          "parameters, which a route fills from the URL"

      Ctx.error(ctx, "bad-app-shape", message)
    end)
  end

  defp app_init(ctx, init, name, step), do: app_def(ctx, init, name, {:arrow, [], step})

  # `name`, when declared, is a def of exactly type `expected`.
  defp app_def(ctx, nil, _name, _expected), do: ctx

  defp app_def(ctx, {:def, params, ret, _names}, name, expected) do
    actual = {:arrow, params, ret}

    if fits_shape?(actual, expected) do
      ctx
    else
      message = "`#{name}` must have type #{Quote.type(expected)}, got #{Quote.type(actual)}"
      Ctx.error(ctx, "bad-app-shape", message)
    end
  end

  defp app_def(ctx, _sig, name, _expected),
    do: Ctx.error(ctx, "bad-app-shape", "`#{name}` must be a def")

  # `actual` is `expected`, a bare `Html` in it fitting any `Html<_>`: that
  # `Html` is refused in the declaration that writes it, and only there.
  defp fits_shape?({:named, "Html"}, {:applied, "Html", _}), do: true

  defp fits_shape?({:applied, a, as}, {:applied, e, es}), do: a == e and all_fit?(as, es)

  defp fits_shape?({:arrow, aps, ar}, {:arrow, eps, er}),
    do: all_fit?(aps, eps) and fits_shape?(ar, er)

  defp fits_shape?({:tuple, as}, {:tuple, es}), do: all_fit?(as, es)
  defp fits_shape?(actual, expected), do: actual == expected

  defp all_fit?(as, es),
    do:
      length(as) == length(es) and Enum.all?(Enum.zip(as, es), fn {a, e} -> fits_shape?(a, e) end)
end
