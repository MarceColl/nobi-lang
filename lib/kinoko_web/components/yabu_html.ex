defmodule KinokoWeb.YabuHtml do
  @moduledoc """
  Safe rendering of Yabu `Html` values.

  `prepare/2` is pure: it walks the Yabu value and returns `{tree, handlers}`.
  The tree holds only strings and tuples (no Yabu terms), so nothing from the
  evaluator reaches the browser; `handlers` maps handler ids to what the
  LiveView must do with the event: `{kind, msg}` with kind
  `:click|:blur|:focus|:keydown|:keyup|:submit`, or `{:change, fun}`
  (`on-change`). An id is `"r<N>.e<i>"`: `N` the render number the caller
  passes (so an event names the render it was clicked in) and `i` the
  handler's pre-order position in that render.

  Tree shapes:

    * `{:text, string}`
    * `{:el, tag, attrs, children}`, attrs a list of `{name, string | true}`
    * `{:change, el}` an input-like element bound with `on-change`

  Safety rules:

    * Tags are allow-listed (`@tags`). A disallowed element (`script`, `style`,
      `iframe`, `object`, `embed`, `link`, `meta`, `base`, ...) renders as
      nothing, children included.
    * Attributes are allow-listed (`@attrs`, plus `aria-*`). Everything else,
      including plain `phx-*`/`on*` names and `style`/`action`, is dropped.
    * `href`/`src` keep only http, https or scheme-less URLs.
    * Values are coerced to strings; boolean attributes render present or absent.
    * HEEx escapes all text and attribute values; nothing is raw HTML.
    * Ids starting `phx-` (LiveView's) or `kinoko-` (the host page's) are
      dropped, so an app can never shadow an element the host relies on.

  Events. The LiveView event name carries the kind, `"yabu:<kind>"`, and
  the id sits under that kind's own key: LiveView sends every
  `phx-value-*` of an element with any of its events, so the kind picks
  which key to read.

    * `on-click|blur|focus|keydown|keyup`: `phx-<event>="yabu:<event>"` plus
      `phx-value-<event>="id"`. Params `%{"click" => id}` (or `"blur"`,
      `"focus"`, `"keydown"`, `"keyup"`; key events add `"key"`, `"value"`).
    * `on-submit` on a `form`: `phx-submit="yabu:submit"` and a hidden input
      named `yabu_submit` holding the id. Params `%{"yabu_submit" => id, ...fields}`.
      A `form` nested in another Yabu form renders as a `div`; its on-submit is lost.
    * Every other form (a Yabu `form` without on-submit, and the wrapper
      below) still gets `phx-submit="yabu:submit"`, with no id: Enter in
      one of its inputs is then a LiveView event the server ignores rather
      than a native submit that reloads the page.
    * `on-change` on `input`/`textarea`/`select`: the element is named
      `yabu[id]` and the handler is read from `_target`. Params
      `%{"_target" => ["yabu", id], "yabu" => %{id => value}}`, event
      `"yabu:change"`. LiveView only fires `phx-change` from forms, so: inside
      a Yabu `form` that form gets `phx-change="yabu:change"` (no extra
      form); a standalone element (no ancestor form) gets a minimal
      `<form phx-change="yabu:change" phx-submit="yabu:submit" class="contents">` wrapper.

  "Relative" URLs include protocol-relative `//host/path`, which is allowed
  like https.
  """

  use Phoenix.Component

  @tags ~w(div span p a ul ol li h1 h2 h3 h4 h5 h6 button input textarea select option
           optgroup label form fieldset legend section header footer nav main article aside
           img table thead tbody tfoot tr td th caption strong em b i u s small code pre br hr
           blockquote dl dt dd figure figcaption details summary mark sub sup time abbr)

  @void ~w(br hr img input)

  @attrs ~w(class id href src alt title type name value placeholder checked disabled selected
            readonly required multiple autofocus rows cols colspan rowspan min max step
            maxlength minlength width height tabindex role for rel target lang dir open
            autocomplete)

  @boolean ~w(checked disabled selected readonly required multiple autofocus open)

  @aria ~r/\Aaria-[a-z]+\z/
  @data ~r/\Adata-[a-z0-9][a-z0-9-]*\z/

  @simple_events ~w(click blur focus keydown keyup)
  # Handler kinds are fixed atoms (never built from user strings).
  @event_kinds %{
    "click" => :click,
    "blur" => :blur,
    "focus" => :focus,
    "keydown" => :keydown,
    "keyup" => :keyup
  }

  @change_tags ~w(input textarea select)

  # ---------- prepare ----------

  @doc """
  Walk a Yabu `Html` value into `{tree, handlers}`, its handler ids stamped
  with render number `render`. Pure.
  """
  @spec prepare(term, non_neg_integer()) :: {tuple | nil, %{String.t() => term}}
  def prepare(html, render \\ 0) when is_integer(render) and render >= 0 do
    acc = %{prefix: "r#{render}.e", n: 0, handlers: %{}, changed?: false}
    {node, acc} = walk(html, false, acc)
    {node, acc.handlers}
  end

  # `in_form?`: an ancestor Yabu `form`. The accumulator carries the id
  # prefix, the next handler number, the handlers, and whether the current
  # form has an on-change child.
  defp walk({:var, "Html", "Text", [s]}, _in_form?, acc) when is_binary(s),
    do: {{:text, String.replace_invalid(s)}, acc}

  defp walk({:var, "Html", "Element", [tag, attrs, children]}, in_form?, acc)
       when is_binary(tag) and is_list(attrs) and is_list(children) do
    tag = String.downcase(tag)
    # A form inside a form is a `div`: the HTML parser would drop the inner
    # `<form>` anyway, so the DOM matches the tree. Its on-submit is lost.
    tag = if tag == "form" and in_form?, do: "div", else: tag
    if tag in @tags, do: element(tag, attrs, children, in_form?, acc), else: {nil, acc}
  end

  defp walk(_other, _in_form?, acc), do: {nil, acc}

  defp element(tag, attrs, children, in_form?, acc) do
    plain = for {name, value} <- attrs, attr = plain_attr(name, value), do: attr
    {event_attrs, change, acc} = events(tag, attrs, acc)

    {outer_changed?, acc} = enter(tag, acc)
    kid_form? = in_form? or tag == "form"

    {kids, acc} =
      Enum.map_reduce(children, acc, fn child, acc -> walk(child, kid_form?, acc) end)

    kids = Enum.reject(kids, &is_nil/1)
    {form_attrs, acc} = leave(tag, event_attrs, outer_changed?, acc)

    el = {:el, tag, plain ++ event_attrs ++ form_attrs, kids}

    case {change, in_form?} do
      {nil, _} -> {el, acc}
      {id, true} -> {name_change(el, id), %{acc | changed?: true}}
      {id, false} -> {{:change, name_change(el, id)}, acc}
    end
  end

  # A form scopes its own on-change flag.
  defp enter("form", acc), do: {acc.changed?, %{acc | changed?: false}}
  defp enter(_tag, acc), do: {false, acc}

  # A form gets `phx-change` when an input in it has on-change, and always
  # a `phx-submit` (its on-submit's, else an id-less one).
  defp leave("form", event_attrs, outer, acc) do
    change = if acc.changed?, do: [{"phx-change", "yabu:change"}], else: []

    submit =
      if List.keymember?(event_attrs, "phx-submit", 0),
        do: [],
        else: [{"phx-submit", "yabu:submit"}]

    {change ++ submit, %{acc | changed?: outer}}
  end

  defp leave(_tag, _event_attrs, _outer, acc), do: {[], acc}

  defp name_change({:el, tag, attrs, kids}, id),
    do:
      {:el, tag, Enum.reject(attrs, &match?({"name", _}, &1)) ++ [{"name", "yabu[#{id}]"}], kids}

  # Handler ids are assigned in attribute order within an element.
  defp events(tag, attrs, acc) do
    Enum.reduce(attrs, {[], nil, acc}, fn
      {"on-" <> event, value}, {evs, change, acc} ->
        id = acc.prefix <> Integer.to_string(acc.n)

        cond do
          event in @simple_events and not is_function(value) ->
            evs = evs ++ [{"phx-#{event}", "yabu:#{event}"}, {"phx-value-#{event}", id}]
            {evs, change, add(acc, id, {@event_kinds[event], value})}

          event == "submit" and tag == "form" and not is_function(value) ->
            evs = evs ++ [{"phx-submit", "yabu:submit"}, {"data-yabu-submit", id}]
            {evs, change, add(acc, id, {:submit, value})}

          event == "change" and tag in @change_tags and is_function(value) and change == nil ->
            {evs, id, add(acc, id, {:change, value})}

          true ->
            {evs, change, acc}
        end

      _, st ->
        st
    end)
  end

  defp add(acc, id, handler),
    do: %{acc | n: acc.n + 1, handlers: Map.put(acc.handlers, id, handler)}

  defp plain_attr(name, value) when is_binary(name) do
    name = String.downcase(name)

    with true <- valid_name?(name),
         {_, v} = attr when is_binary(v) or v == true <- coerce(name, value),
         true <- reserved_ok?(name, v) do
      attr
    else
      _ -> nil
    end
  end

  defp plain_attr(_, _), do: nil

  # `name`s the event routing owns, and `id`s LiveView and the host own.
  defp reserved_ok?("name", v) when is_binary(v),
    do:
      v not in ["yabu", "yabu_submit", "_target", "h"] and
        not String.starts_with?(v, ["yabu[", "yabu_"])

  defp reserved_ok?("id", v) when is_binary(v),
    do: not String.starts_with?(String.downcase(v), ["phx-", "kinoko-"])

  defp reserved_ok?(_, _), do: true

  # Strict: every name is exact-listed or matches an anchored pattern, so no
  # whitespace, `=`, quote or `>` can ever reach the tag.
  defp valid_name?(name) do
    name in @attrs or Regex.match?(@aria, name) or
      (Regex.match?(@data, name) and not String.starts_with?(name, ["data-phx-", "data-yabu-"]))
  end

  defp coerce(name, value) when name in @boolean do
    case value do
      false -> nil
      "false" -> nil
      _ -> {name, true}
    end
  end

  defp coerce(name, value) do
    with s when is_binary(s) <- stringify(value),
         true <- String.valid?(s),
         true <- name not in ["href", "src"] or safe_url?(s) do
      {name, s}
    else
      _ -> nil
    end
  end

  defp stringify(s) when is_binary(s), do: s
  defp stringify(n) when is_integer(n), do: Integer.to_string(n)
  defp stringify(b) when is_boolean(b), do: Atom.to_string(b)
  defp stringify({:uuid, s}) when is_binary(s), do: s
  defp stringify(_), do: nil

  @doc false
  def safe_url?(url) when not is_binary(url), do: false

  def safe_url?(url) do
    String.valid?(url) and scheme_ok?(url)
  end

  defp scheme_ok?(url) do
    # Browsers ignore whitespace and control characters inside a scheme.
    squeezed = url |> String.replace(~r/[\x00-\x20]/u, "") |> String.downcase()

    case Regex.run(~r/\A([a-z][a-z0-9+.\-]*):/, squeezed) do
      nil -> true
      [_, scheme] -> scheme in ["http", "https"]
    end
  end

  # ---------- rendering ----------

  attr :tree, :any, required: true, doc: "the tree from `prepare/1`"

  @doc "Render a prepared tree."
  def yabu_html(assigns), do: ~H"<.yabu_node node={@tree} />"

  # Templates are single-line on purpose: no whitespace may leak into
  # `textarea`/`pre` content.
  attr :node, :any, required: true

  defp yabu_node(%{node: nil} = assigns), do: ~H""
  defp yabu_node(%{node: {:text, text}} = assigns), do: assign(assigns, :text, text) |> text()

  defp yabu_node(%{node: {:change, el}} = assigns),
    do: assign(assigns, :el, el) |> change_form()

  defp yabu_node(%{node: {:el, tag, attrs, kids}} = assigns) do
    {submit, attrs} =
      case List.keytake(attrs, "data-yabu-submit", 0) do
        {{_, id}, rest} -> {id, rest}
        nil -> {nil, attrs}
      end

    assigns = assign(assigns, tag: tag, attrs: attrs, kids: kids, submit: submit)
    if tag in @void, do: void(assigns), else: element(assigns)
  end

  defp text(assigns), do: ~H"{@text}"

  defp change_form(assigns),
    do: ~H|<form phx-change="yabu:change" phx-submit="yabu:submit" class="contents">
  <.yabu_node node={@el} />
</form>|

  defp void(assigns), do: ~H"<.dynamic_tag tag_name={@tag} {@attrs} />"

  defp element(assigns),
    do: ~H"<.dynamic_tag tag_name={@tag} {@attrs}><.kids s={@submit} k={@kids} /></.dynamic_tag>"

  defp kids(assigns),
    do: ~H"<.submit_field :if={@s} id={@s} /><.yabu_node :for={n <- @k} node={n} />"

  defp submit_field(assigns),
    do: ~H|<input type="hidden" name="yabu_submit" value={@id} />|
end
