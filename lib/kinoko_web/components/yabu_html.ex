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

  Events (params sent to the LiveView `"yabu"` event):

    * `on-click|blur|focus|keydown|keyup` become `phx-<event>="yabu"` plus
      `phx-value-h="eN"`. Params: `%{"h" => "eN", ...}` (key events add `"key"`).
    * `on-submit` becomes `phx-submit="yabu"` on the form with a hidden `h`
      field. Params: `%{"h" => "eN", ...form fields}`.
    * `on-change` on `input`/`textarea`/`select`: LiveView only fires
      `phx-change` from inside a form, so the element is wrapped in its own
      `<form phx-change="yabu" class="contents">` (no layout impact) with a
      hidden `h` field, and the element is named `value`. Params:
      `%{"h" => "eN", "value" => input_value, "_target" => ["value"]}`.
  """

  use Phoenix.Component

  @tags ~w(div span p a ul ol li h1 h2 h3 h4 h5 h6 button input textarea select option
           optgroup label form fieldset legend section header footer nav main article aside
           img table thead tbody tfoot tr td th caption strong em b i u s small code pre br hr
           blockquote dl dt dd figure figcaption details summary mark sub sup time abbr
           svg path circle rect line g)

  @void ~w(br hr img input)

  @attrs ~w(class id href src alt title type name value placeholder checked disabled selected
            readonly required multiple autofocus rows cols colspan rowspan min max step
            maxlength minlength width height tabindex role for rel target lang dir open
            autocomplete)

  @boolean ~w(checked disabled selected readonly required multiple autofocus open)

  @simple_events ~w(click blur focus keydown keyup)
  @change_tags ~w(input textarea select)

  # ---------- prepare ----------

  @doc "Walk a Yabu `Html` value into `{tree, handlers}`. Pure."
  @spec prepare(term) :: {tuple | nil, %{String.t() => term}}
  def prepare(html) do
    {node, {_n, handlers}} = walk(html, {0, %{}})
    {node, handlers}
  end

  defp walk({:var, "Html", "Text", [s]}, acc) when is_binary(s), do: {{:text, s}, acc}

  defp walk({:var, "Html", "Element", [tag, attrs, children]}, acc)
       when is_binary(tag) and is_list(attrs) and is_list(children) do
    tag = String.downcase(tag)

    if tag in @tags do
      element(tag, attrs, children, acc)
    else
      {nil, acc}
    end
  end

  defp walk(_other, acc), do: {nil, acc}

  defp element(tag, attrs, children, acc) do
    plain = for {name, value} <- attrs, attr = plain_attr(name, value), do: attr
    {event_attrs, change, acc} = events(tag, attrs, acc)

    {kids, acc} =
      children
      |> Enum.map_reduce(acc, &walk/2)
      |> then(fn {nodes, acc} -> {Enum.reject(nodes, &is_nil/1), acc} end)

    el = {:el, tag, plain ++ event_attrs, kids}

    case change do
      nil -> {el, acc}
      id -> {{:change, id, change_name(el)}, acc}
    end
  end

  defp change_name({:el, tag, attrs, kids}),
    do: {:el, tag, List.keystore(attrs, "name", 0, {"name", "value"}), kids}

  # Handler ids are assigned in attribute order within an element.
  defp events(tag, attrs, acc) do
    Enum.reduce(attrs, {[], nil, acc}, fn
      {"on-" <> event, value}, {evs, change, {n, hs} = acc} ->
        cond do
          event in @simple_events and not is_function(value) ->
            id = "e#{n}"

            {evs ++ [{"phx-#{event}", "yabu"}, {"phx-value-h", id}], change,
             {n + 1, Map.put(hs, id, value)}}

          event == "submit" and tag == "form" and not is_function(value) ->
            id = "e#{n}"

            {evs ++ [{"phx-submit", "yabu"}, {"data-yabu-h", id}], change,
             {n + 1, Map.put(hs, id, value)}}

          event == "change" and tag in @change_tags and is_function(value) and change == nil ->
            id = "e#{n}"
            {evs, id, {n + 1, Map.put(hs, id, {:change, value})}}

          true ->
            {evs, change, acc}
        end

      _, st ->
        st
    end)
  end

  defp plain_attr(name, value) when is_binary(name) do
    name = String.downcase(name)

    if name in @attrs or String.starts_with?(name, "aria-") do
      coerce(name, value)
    end
  end

  defp plain_attr(_, _), do: nil

  defp coerce(name, value) when name in @boolean do
    case value do
      false -> nil
      "false" -> nil
      _ -> {name, true}
    end
  end

  defp coerce(name, value) do
    case stringify(value) do
      nil -> nil
      s when name in ["href", "src"] -> if safe_url?(s), do: {name, s}
      s -> {name, s}
    end
  end

  defp stringify(s) when is_binary(s), do: s
  defp stringify(n) when is_integer(n), do: Integer.to_string(n)
  defp stringify(b) when is_boolean(b), do: Atom.to_string(b)
  defp stringify({:uuid, s}) when is_binary(s), do: s
  defp stringify(_), do: nil

  @doc false
  def safe_url?(url) do
    # Browsers ignore whitespace and control characters inside a scheme.
    squeezed = url |> String.replace(~r/[\x00-\x20]/u, "") |> String.downcase()

    case Regex.run(~r/^([a-z][a-z0-9+.\-]*):/, squeezed) do
      nil -> true
      [_, scheme] -> scheme in ["http", "https"]
    end
  end

  # ---------- rendering ----------

  attr :tree, :any, required: true, doc: "the tree from `prepare/1`"

  @doc "Render a prepared tree."
  def yabu_html(assigns) do
    ~H"""
    <.yabu_node node={@tree} />
    """
  end

  attr :node, :any, required: true

  defp yabu_node(%{node: nil} = assigns), do: ~H""
  defp yabu_node(%{node: {:text, text}} = assigns), do: assign(assigns, :text, text) |> text()

  defp yabu_node(%{node: {:change, id, el}} = assigns) do
    assigns = assign(assigns, id: id, el: el)

    ~H"""
    <form phx-change="yabu" class="contents">
      <input type="hidden" name="h" value={@id} />
      <.yabu_node node={@el} />
    </form>
    """
  end

  defp yabu_node(%{node: {:el, tag, attrs, kids}} = assigns) do
    # on-submit carries its id as a hidden `h` field the form renders.
    {hidden, attrs} =
      case List.keytake(attrs, "data-yabu-h", 0) do
        {{_, id}, rest} -> {id, rest}
        nil -> {nil, attrs}
      end

    assigns =
      assign(assigns, tag: tag, attrs: attrs, kids: kids, hidden: hidden, void: tag in @void)

    ~H"""
    <%= if @void do %>
      <.dynamic_tag tag_name={@tag} {@attrs} />
    <% else %>
      <.dynamic_tag tag_name={@tag} {@attrs}>
        <input :if={@hidden} type="hidden" name="h" value={@hidden} />
        <.yabu_node :for={kid <- @kids} node={kid} />
      </.dynamic_tag>
    <% end %>
    """
  end

  defp text(assigns), do: ~H"{@text}"
end
