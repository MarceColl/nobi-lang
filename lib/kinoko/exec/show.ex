defmodule Kinoko.Exec.Show do
  @moduledoc """
  A value as Yabu source text (ported from kinoko-next `interp/value.rs`'s
  `Display`): the literal that builds it, spelled by
  `Kinoko.Lang.Format.expr/1`, so a value source can write reads back as
  itself (`Kinoko.Exec.eval(u, show(v))` is `v`).

  | Value | Written |
  |---|---|
  | Int, String, Bool | `-3`, `"say \\"hi\\""`, `true` |
  | List, Map, tuple | `[1, 2]`, `%{"a" => 1}` (keys in Yabu order), `(1, "x")`, `()` |
  | record | `%M.Model{by: "me", count: 1}` (fields by name; a record built in memory has no `id`) |
  | variant | `M.Msg.Add(1)`, `Option.None` |
  | Html element | JSX: `<p class="x" on-click={M.Msg.Go} n={1}>hi</p>`; a text child that would not read back as itself (padded, holding `<` or `{`, or following another text child) is `{"…"}` |
  | Html text alone | `Html.Text("hi")` |
  | Cmd | `Cmd.none()`, `Cmd.batch([...])`, an effect as its call: `Cmd.store.list(<fn M.Msg.Rows>)` (a store read's model is its callback's type's, as in source) |
  | Uuid | `<uuid 0b9e2c4a-…>` (source has no Uuid literal) |
  | function | `<fn M.f>` for a def (the image's or the stdlib's), `<fn M.Msg.Add>` for a constructor, `<fn>` for a closure |

  A preview, never a dump: at most #{10_000} nodes are written (a string
  counting one more per 64 bytes) and nothing deeper than 64 levels; the
  rest is `…`, as in Rust.
  """

  alias Kinoko.Lang.Format
  alias Kinoko.Lang.Rt
  alias Kinoko.Lang.Rt.Stdlib
  alias Kinoko.Lang.Types.Stdlib, as: StdlibSigs

  @depth 64
  @nodes 10_000
  @bytes 64
  @elided "…"

  # The stdlib def each of `Rt.Stdlib`'s functions is.
  @stdlib for {name, {:def, _, _}} <- StdlibSigs.signatures(),
              {_, f, a} <- [Stdlib.function_for(name)],
              into: %{},
              do: {{f, a}, name}

  @doc "`value` as Yabu source; `type` (its type, or `nil`) changes nothing: every value carries what its spelling needs."
  @spec show(term(), term()) :: String.t()
  def show(value, _type \\ nil) do
    {e, _left} = literal(value, @nodes, 0)
    Format.expr(e)
  end

  defp node(kind, args), do: {kind, [], args}
  defp name(n), do: node(:name, [n])
  defp elided, do: name(@elided)

  # `v`'s literal, `v` being `depth` levels deep, and the nodes left.
  defp literal(_v, left, _depth) when left <= 0, do: {elided(), 0}
  defp literal(v, left, depth), do: kind(v, left - 1, depth + 1)

  defp kind(n, left, _) when is_integer(n), do: {node(:int, [n]), left}
  defp kind(b, left, _) when is_boolean(b), do: {node(:bool, [b]), left}
  defp kind(s, left, _) when is_binary(s), do: string(s, left)
  defp kind({:uuid, s}, left, _), do: {name("<uuid #{s}>"), left}

  defp kind(items, left, below) when is_list(items) do
    {es, left} = all(items, left, below)
    {node(:list, es), left}
  end

  defp kind(map, left, below) when is_map(map) do
    {entries, left} =
      seq(
        entries(map),
        left,
        below,
        fn {k, v}, left ->
          {k, left} = literal(k, left, below)
          {v, left} = literal(v, left, below)
          {:ok, {k, v}, left}
        end,
        {elided(), elided()}
      )

    {node(:map, entries), left}
  end

  defp kind({:rec, model, fields}, left, below) when is_map(fields) do
    {fs, left} =
      seq(
        Enum.sort(fields),
        left,
        below,
        fn {f, v}, left ->
          {e, left} = literal(v, left, below)
          {:ok, {f, e}, left}
        end,
        {@elided, elided()}
      )

    {node(:construct, [model, fs]), left}
  end

  defp kind({:var, _, _, _} = v, left, below) do
    case element(v) do
      {tag, attrs, children} ->
        case jsx(tag, attrs, children, left, below) do
          {:ok, j, left} -> {j, left}
          {:none, left} -> {elided(), left}
        end

      nil ->
        {:var, owner, variant, args} = v

        case args do
          [] ->
            {name("#{owner}.#{variant}"), left}

          args ->
            {es, left} = all(args, left, below)
            {node(:call, ["#{owner}.#{variant}", es]), left}
        end
    end
  end

  defp kind({:cmd, cmd}, left, below), do: cmd(cmd, left, below)
  defp kind(f, left, _) when is_function(f), do: {name(fun_name(f)), left}

  defp kind(t, left, below) when is_tuple(t) do
    {es, left} = all(Tuple.to_list(t), left, below)
    {node(:tuple, es), left}
  end

  # A map's entries in Yabu key order. All-Int and all-String keys order
  # the same in Yabu and in Erlang's term order, so a plain sort serves
  # (native, uncharged); only other keys take `Rt`'s charged comparator.
  defp entries(map) do
    pairs = Map.to_list(map)

    if Enum.all?(pairs, fn {k, _} -> is_integer(k) end) or
         Enum.all?(pairs, fn {k, _} -> is_binary(k) end),
       do: Enum.sort(pairs),
       else: Rt.sorted_entries(map)
  end

  # The call that builds `cmd`, its parts at depth `at`.
  defp cmd(:none, left, _), do: {node(:call, ["Cmd.none", []]), left}

  defp cmd({:batch, cmds}, left, at) do
    {cs, left} =
      seq(
        cmds,
        left,
        at + 1,
        fn c, left ->
          {e, left} = batched(c, left, at + 1)
          {:ok, e, left}
        end,
        elided()
      )

    {node(:call, ["Cmd.batch", [node(:list, cs)]]), left}
  end

  defp cmd({:effect, effect, _model, args}, left, at) do
    {es, left} = all(args, left, at)
    {node(:call, [effect, es]), left}
  end

  # One command of a batch, `depth` levels deep.
  defp batched(_c, left, _depth) when left <= 0, do: {elided(), 0}
  defp batched(c, left, depth), do: cmd(c, left - 1, depth + 1)

  # Each of `items` built by `each` while nodes are left and their depth
  # `at` is within the cap, then one `elide` for the rest, from the first
  # `each` finds no room for (`:none`).
  defp seq(items, left, at, each, elide), do: seq(items, left, at, each, elide, [])

  defp seq([], left, _at, _each, _elide, acc), do: {Enum.reverse(acc), left}

  defp seq([item | rest], left, at, each, elide, acc) do
    if left > 0 and at < @depth do
      case each.(item, left) do
        {:ok, built, left} -> seq(rest, left, at, each, elide, [built | acc])
        {:none, left} -> {Enum.reverse([elide | acc]), left}
      end
    else
      {Enum.reverse([elide | acc]), left}
    end
  end

  defp all(values, left, at),
    do: seq(values, left, at, fn v, left -> wrap(literal(v, left, at)) end, elided())

  defp wrap({e, left}), do: {:ok, e, left}

  # An element as JSX, its attributes and children at depth `at`: an `on-`
  # attribute is an event, another holding a string is text. A tag or an
  # attribute's name is written whole, its bytes counted as a string's:
  # `:none` when the tag does not fit, and the attributes end at the first
  # name that does not.
  defp jsx(tag, attrs, children, left, at) do
    case text(tag, left) do
      :none ->
        {:none, left}

      {:ok, tag, left} ->
        {as, left} = seq(pairs(attrs), left, at, &attr(&1, &2, at), {:expr, @elided, elided()})
        {cs, left} = seq(children, left, at, &wrap(child(&1, &2, at)), {:expr, elided()})
        {:ok, node(:jsx, [tag, as, separate_texts(cs)]), left}
    end
  end

  # Attributes up to the first that is no `{name, value}` pair.
  defp pairs(attrs), do: Enum.take_while(attrs, &match?({n, _} when is_binary(n), &1))

  defp attr({name, value}, left, at) do
    case text(name, left) do
      :none ->
        {:none, left}

      {:ok, name, left} ->
        case {name, value} do
          {"on-" <> event, _} ->
            {e, left} = literal(value, left, at)
            {:ok, {:event, event, e}, left}

          {_, s} when is_binary(s) ->
            left = max(left - 1, 0)

            case text(s, left) do
              {:ok, s, left} -> {:ok, {:text, name, s}, left}
              :none -> wrap_attr(name, cut(s, left))
            end

          _ ->
            {e, left} = literal(value, left, at)
            {:ok, {:expr, name, e}, left}
        end
    end
  end

  defp wrap_attr(name, {e, left}), do: {:ok, {:expr, name, e}, left}

  # An element's child, `depth` levels deep: an element, text where it
  # reads back as itself, or else an interpolation.
  defp child(v, left, depth) do
    case {html_text(v), element(v)} do
      {t, e} when (t != nil or e != nil) and left <= 0 ->
        {{:expr, elided()}, 0}

      {t, _} when is_binary(t) ->
        left = left - 1

        case text(t, left) do
          {:ok, t, left} ->
            if reads_back_as_text?(t),
              do: {{:text, t}, left},
              else: {{:expr, node(:str, [t])}, left}

          :none ->
            {e, left} = cut(t, left)
            {{:expr, e}, left}
        end

      {nil, {tag, attrs, children}} ->
        case jsx(tag, attrs, children, left - 1, depth + 1) do
          {:ok, j, left} -> {{:element, j}, left}
          {:none, left} -> {{:expr, elided()}, left}
        end

      {nil, nil} ->
        {e, left} = literal(v, left, depth)
        {{:expr, e}, left}
    end
  end

  # Two text children in a row would read back as one: the second is
  # written as a string interpolation. (Rust's `Display` writes both as
  # text; here `eval(show(v))` gives `v` back.)
  defp separate_texts([{:text, _} = a, {:text, t} | rest]),
    do: [a | separate_texts([{:expr, node(:str, [t])} | rest])]

  defp separate_texts([c | rest]), do: [c | separate_texts(rest)]
  defp separate_texts([]), do: []

  # `s` whole (a string, a tag, an attribute's name), taking a node for
  # each 64 bytes of it; `:none`, taking none, when too few are left.
  defp text(s, left) do
    nodes = div(byte_size(s), @bytes)
    if nodes <= left, do: {:ok, s, left - nodes}, else: :none
  end

  # `s` as a string literal, cut short if too few nodes are left.
  defp string(s, left) do
    case text(s, left) do
      {:ok, s, left} -> {node(:str, [s]), left}
      :none -> cut(s, left)
    end
  end

  # As much of `s` as the nodes left write, `++ …`, taking them all.
  defp cut(s, left) do
    part = prefix(s, min(left * @bytes, byte_size(s)))

    case part do
      "" -> {elided(), 0}
      part -> {node(:bin, [:++, node(:str, [part]), elided()]), 0}
    end
  end

  # The longest prefix of `s` of at most `n` bytes ending on a character
  # boundary.
  defp prefix(s, n) do
    part = binary_part(s, 0, n)
    if String.valid?(part) or n == 0, do: part, else: prefix(s, n - 1)
  end

  # An `Html.Element`'s tag, attributes and children, if its attributes, as
  # far as a preview writes them, are `{name, value}` pairs.
  defp element({:var, "Html", "Element", [tag, attrs, children]})
       when is_binary(tag) and is_list(attrs) and is_list(children) do
    pairs? = attrs |> Enum.take(@nodes) |> Enum.all?(&match?({n, _} when is_binary(n), &1))
    if pairs?, do: {tag, attrs, children}
  end

  defp element(_), do: nil

  defp html_text({:var, "Html", "Text", [t]}) when is_binary(t), do: t
  defp html_text(_), do: nil

  # Whether `text`, written as a JSX text child, reads back as itself: the
  # parser ends a text run at `<` or `{` and trims it.
  defp reads_back_as_text?(text),
    do: text != "" and String.trim(text) == text and not String.contains?(text, ["<", "{"])

  # A function's name, as far as its term tells it.
  defp fun_name(f) do
    case Function.info(f, :type) do
      {:type, :external} -> external_name(f)
      {:type, :local} -> ctor_name(f)
    end
  end

  defp external_name(f) do
    {:module, m} = Function.info(f, :module)
    {:name, n} = Function.info(f, :name)
    {:arity, a} = Function.info(f, :arity)

    found =
      cond do
        m == Stdlib -> Map.get(@stdlib, {n, a})
        image_module?(m) -> image_def(m, n, a)
        true -> nil
      end

    if found, do: "<fn #{found}>", else: "<fn>"
  end

  defp image_module?(m), do: String.starts_with?(Atom.to_string(m), "yabu_img_")

  # The def of a loaded image module that `n/a` is.
  defp image_def(m, n, a) do
    if function_exported?(m, :__yabu__, 1) do
      Enum.find_value(m.__yabu__(:names), fn {name, fa} -> if fa == {n, a}, do: name end)
    end
  end

  # A constructor as a value is `Rt.ctor/3`'s fun: applied to placeholders
  # (it only builds the variant) it names its owner and variant.
  defp ctor_name(f) do
    {:module, m} = Function.info(f, :module)
    {:name, n} = Function.info(f, :name)
    {:arity, a} = Function.info(f, :arity)

    with true <- m == Rt and String.starts_with?(Atom.to_string(n), "-ctor/3-"),
         {:var, owner, variant, _} <- apply(f, List.duplicate(nil, a)) do
      "<fn #{owner}.#{variant}>"
    else
      _ -> "<fn>"
    end
  end
end
