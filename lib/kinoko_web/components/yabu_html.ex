defmodule KinokoWeb.YabuHtml do
  @moduledoc """
  Safe rendering of Yabu `Html` values.

  `prepare/1` is pure: it walks the Yabu value and returns `{tree, handlers}`.
  The tree holds only strings and tuples (no Yabu terms), so nothing from the
  evaluator reaches the browser; `handlers` maps `"eN"` ids (assigned in
  pre-order render order) to what the LiveView must do with the event:
  a message term (`on-click` and friends), or `{:change, fun}` (`on-change`).

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

  Events (params of the LiveView `"yabu"` event; `id` is the `"eN"` handler id):

    * `on-click|blur|focus|keydown|keyup`: `phx-<event>="yabu"` plus
      `phx-value-h="id"`. Params `%{"h" => id}` (key events add `"key"`, `"value"`).
    * `on-submit` on a `form`: `phx-submit="yabu"` and a hidden input named
      `yabu_submit` holding the id. Params `%{"yabu_submit" => id, ...fields}`.
    * `on-change` on `input`/`textarea`/`select`: the element is named
      `yabu[id]` and the handler is read from `_target`. Params
      `%{"_target" => ["yabu", id], "yabu" => %{id => value}}`. LiveView only
      fires `phx-change` from forms, so: inside a Yabu `form` that form gets
      `phx-change="yabu"` (no extra form); a standalone element (no ancestor
      form) gets a minimal `<form phx-change="yabu" class="contents">` wrapper.

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
  @change_tags ~w(input textarea select)

  # ---------- prepare ----------

  @doc "Walk a Yabu `Html` value into `{tree, handlers}`. Pure."
  @spec prepare(term) :: {tuple | nil, %{String.t() => term}}
  def prepare(html) do
    {node, {_n, handlers, _changed?}} = walk(html, false, {0, %{}, false})
    {node, handlers}
  end

  # `in_form?`: an ancestor Yabu `form`. The accumulator carries the next
  # handler id, the handlers, and whether the current form has an on-change child.
  defp walk({:var, "Html", "Text", [s]}, _in_form?, acc) when is_binary(s),
    do: {{:text, String.replace_invalid(s)}, acc}

  defp walk({:var, "Html", "Element", [tag, attrs, children]}, in_form?, acc)
       when is_binary(tag) and is_list(attrs) and is_list(children) do
    tag = String.downcase(tag)
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
    {form_change, acc} = leave(tag, outer_changed?, acc)

    el = {:el, tag, plain ++ event_attrs ++ form_change, kids}

    case {change, in_form?} do
      {nil, _} -> {el, acc}
      {id, true} -> {name_change(el, id), mark_changed(acc)}
      {id, false} -> {{:change, name_change(el, id)}, acc}
    end
  end

  # A form scopes its own on-change flag.
  defp enter("form", {n, hs, changed?}), do: {changed?, {n, hs, false}}
  defp enter(_tag, acc), do: {false, acc}

  defp leave("form", outer, {n, hs, changed?}),
    do: {if(changed?, do: [{"phx-change", "yabu"}], else: []), {n, hs, outer}}

  defp leave(_tag, _outer, acc), do: {[], acc}

  defp mark_changed({n, hs, _}), do: {n, hs, true}

  defp name_change({:el, tag, attrs, kids}, id),
    do: {:el, tag, List.keystore(attrs, "name", 0, {"name", "yabu[#{id}]"}), kids}

  # Handler ids are assigned in attribute order within an element.
  defp events(tag, attrs, acc) do
    Enum.reduce(attrs, {[], nil, acc}, fn
      {"on-" <> event, value}, {evs, change, {n, hs, c} = acc} ->
        id = "e#{n}"

        cond do
          event in @simple_events and not is_function(value) ->
            {evs ++ [{"phx-#{event}", "yabu"}, {"phx-value-h", id}], change,
             {n + 1, Map.put(hs, id, value), c}}

          event == "submit" and tag == "form" and not is_function(value) ->
            {evs ++ [{"phx-submit", "yabu"}, {"data-yabu-submit", id}], change,
             {n + 1, Map.put(hs, id, value), c}}

          event == "change" and tag in @change_tags and is_function(value) and change == nil ->
            {evs, id, {n + 1, Map.put(hs, id, {:change, value}), c}}

          true ->
            {evs, change, acc}
        end

      _, st ->
        st
    end)
  end

  defp plain_attr(name, value) when is_binary(name) do
    name = String.downcase(name)

    if valid_name?(name), do: coerce(name, value)
  end

  defp plain_attr(_, _), do: nil

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
    do: ~H|<form phx-change="yabu" class="contents"><.yabu_node node={@el} /></form>|

  defp void(assigns), do: ~H"<.dynamic_tag tag_name={@tag} {@attrs} />"

  defp element(assigns),
    do: ~H"<.dynamic_tag tag_name={@tag} {@attrs}><.kids s={@submit} k={@kids} /></.dynamic_tag>"

  defp kids(assigns),
    do: ~H"<.submit_field :if={@s} id={@s} /><.yabu_node :for={n <- @k} node={n} />"

  defp submit_field(assigns),
    do: ~H|<input type="hidden" name="yabu_submit" value={@id} />|
end
