defmodule Kinoko.Lang.Rt.Json do
  @moduledoc """
  `JSON.parse` and `JSON.stringify`, ported in behaviour from kinoko-next
  `interp/json.rs` (itself TS `codegen/emit.ts`'s `$coerce` and `$clean`).

  Both answer a `Result` variant. An `Err` holds TS's reason, with the path
  into the JSON (`$` the whole, `.name` a field, `[i]` a list's element,
  `.i` a tuple's, `["text"]` a map entry), for text that is not JSON or not
  of the type, and Rust's own for a value that is not data (a function, a
  `Cmd`, `Html`).

  Data is written as TS writes it: a record as an object of its fields (its
  model's order, then any other by name), `Option` as its value or `null`,
  a tuple (Unit too) as an array, any other variant as
  `{"$variant": "M.T.V", "values": [...]}`. A map is a plain JSON object in
  Yabu key order (`Kinoko.Lang.Rt.compare/2`): a `String` or `Uuid` key as
  itself, any other key as its own compact JSON text. `parse` reads a key
  back the same way, by the map's declared key type.

  A number is an `Int` when its exact value is a whole number within i64;
  a lone surrogate escape is not JSON. Text or a value nested deeper than
  100,000 levels is refused (text as an `Err`, a value as a runtime error).

  `models` is `%{model => [{field, type, default}]}` (the image's
  `__yabu__(:models)`): what decoding a record needs, and its field order
  for writing one. A record's every field is read; defaults are the
  store's, never JSON's.

  A Tx op is written as the variant its call reads as
  (`Kinoko.Lang.Rt.tx_variant/1`); a `Store` handle is refused, as a
  function is.
  """

  import Kinoko.Lang.Rt, only: [error!: 1]

  alias Kinoko.Lang.Format
  alias Kinoko.Lang.Rt

  @depth_limit 100_000

  # ---------- JSON.parse ----------

  @doc """
  `JSON.parse(text)` decoding into `target`, the `T` of the call's
  `Result<T, String>`. `nil` when there is none (applied as a value).
  """
  def parse(text, target, models) when is_binary(text) do
    cond do
      target == nil ->
        err("JSON.parse has no type to decode into when applied as a value")

      has_var?(target) ->
        err("JSON.parse needs its target type: write (JSON.parse(s) : T)")

      true ->
        case document(text) do
          {:error, why} ->
            err("invalid JSON: " <> reason(why))

          {:ok, json} ->
            try do
              ok(coerce(json, target, [:root], models))
            catch
              {:refused, why} -> err(why)
            end
        end
    end
  end

  defp ok(v), do: {:var, "Result", "Ok", [v]}
  defp err(why), do: {:var, "Result", "Err", [why]}

  defp reason(:too_deep), do: too_deep_text()
  defp reason(why), do: why

  defp too_deep_text, do: "nested deeper than #{@depth_limit} levels"

  defp has_var?({:var, _}), do: true
  defp has_var?({:named, _}), do: false
  defp has_var?({:applied, _, args}), do: Enum.any?(args, &has_var?/1)
  defp has_var?({:tuple, args}), do: Enum.any?(args, &has_var?/1)
  defp has_var?({:arrow, ps, r}), do: Enum.any?(ps, &has_var?/1) or has_var?(r)

  # ---------- reading ----------

  # JSON as read: `nil`, booleans, `{:num, text}`, `{:str, s}`, lists and
  # `{:obj, %{key => json}}` (a repeated key keeping its last value).
  defp document(text) do
    {json, rest} = value(text, text, 1)

    case space(rest) do
      "" -> {:ok, json}
      rest -> throw({:fail, unexpected(text, rest)})
    end
  catch
    {:fail, why} -> {:error, why}
  end

  defp value(_text, _rest, depth) when depth > @depth_limit, do: throw({:fail, :too_deep})

  defp value(text, rest, depth) do
    case space(rest) do
      "{" <> rest -> object(text, space(rest), depth, %{})
      "[" <> rest -> array(text, space(rest), depth, [])
      rest -> scalar(text, rest)
    end
  end

  defp scalar(text, rest) do
    case rest do
      "\"" <> tail -> with({s, rest} <- string(text, tail, []), do: {{:str, s}, rest})
      <<c, _::binary>> when c == ?- or c in ?0..?9 -> number(text, rest)
      "true" <> tail -> {true, tail}
      "false" <> tail -> {false, tail}
      "null" <> tail -> {nil, tail}
      _ -> throw({:fail, unexpected(text, rest)})
    end
  end

  defp array(_text, "]" <> rest, _depth, []), do: {[], rest}

  defp array(text, rest, depth, acc) do
    {item, rest} = value(text, rest, depth + 1)

    case space(rest) do
      "]" <> rest -> {Enum.reverse([item | acc]), rest}
      "," <> rest -> array(text, rest, depth, [item | acc])
      rest -> throw({:fail, unexpected(text, rest)})
    end
  end

  defp object(_text, "}" <> rest, _depth, acc) when acc == %{}, do: {{:obj, acc}, rest}

  defp object(text, rest, depth, acc) do
    {key, rest} =
      case space(rest) do
        "\"" <> tail -> string(text, tail, [])
        rest -> throw({:fail, unexpected(text, rest)})
      end

    rest =
      case space(rest) do
        ":" <> rest -> rest
        rest -> throw({:fail, unexpected(text, rest)})
      end

    {v, rest} = value(text, rest, depth + 1)
    acc = Map.put(acc, key, v)

    case space(rest) do
      "}" <> rest -> {{:obj, acc}, rest}
      "," <> rest -> object(text, rest, depth, acc)
      rest -> throw({:fail, unexpected(text, rest)})
    end
  end

  # `-`, then `0` or digits not starting with `0`, then perhaps a fraction
  # and an exponent.
  defp number(text, rest) do
    start = rest
    rest = eat(rest, "-")

    rest =
      case rest do
        "0" <> tail -> tail
        _ -> digits!(text, rest)
      end

    rest =
      if match?("." <> _, rest),
        do: digits!(text, binary_part(rest, 1, byte_size(rest) - 1)),
        else: rest

    rest =
      case rest do
        <<e, tail::binary>> when e in [?e, ?E] ->
          tail =
            case tail do
              <<sign, signed::binary>> when sign in [?+, ?-] -> signed
              _ -> tail
            end

          digits!(text, tail)

        _ ->
          rest
      end

    {{:num, binary_part(start, 0, byte_size(start) - byte_size(rest))}, rest}
  end

  defp eat(rest, prefix) do
    case rest do
      <<^prefix::binary, tail::binary>> -> tail
      _ -> rest
    end
  end

  defp digits!(text, rest) do
    case skip_digits(rest) do
      ^rest -> throw({:fail, unexpected(text, rest)})
      tail -> tail
    end
  end

  defp skip_digits(<<c, tail::binary>>) when c in ?0..?9, do: skip_digits(tail)
  defp skip_digits(rest), do: rest

  # A string, its escapes decoded. A control character must be escaped.
  defp string(text, rest, acc) do
    {run, rest} = run(rest, 0, rest)
    acc = [acc | run]

    case rest do
      "\"" <> tail -> {IO.iodata_to_binary(acc), tail}
      "\\" <> tail -> escape(text, tail, acc)
      "" -> throw({:fail, "unterminated string"})
      _ -> throw({:fail, unexpected(text, rest)})
    end
  end

  defp run(<<b, tail::binary>>, n, start) when b != ?" and b != ?\\ and b >= 0x20,
    do: run(tail, n + 1, start)

  defp run(rest, n, start), do: {binary_part(start, 0, n), rest}

  defp escape(text, rest, acc) do
    case rest do
      "\"" <> tail -> string(text, tail, [acc, ?"])
      "\\" <> tail -> string(text, tail, [acc, ?\\])
      "/" <> tail -> string(text, tail, [acc, ?/])
      "b" <> tail -> string(text, tail, [acc, 8])
      "f" <> tail -> string(text, tail, [acc, 12])
      "n" <> tail -> string(text, tail, [acc, ?\n])
      "r" <> tail -> string(text, tail, [acc, ?\r])
      "t" <> tail -> string(text, tail, [acc, ?\t])
      "u" <> tail -> unicode(text, tail, acc)
      _ -> throw({:fail, unexpected(text, rest)})
    end
  end

  # `\uXXXX`, or two of them for a character past the first plane. A
  # surrogate alone is no character a String can hold.
  defp unicode(text, rest, acc) do
    at = byte_size(text) - byte_size(rest) - 2
    lone = fn -> throw({:fail, "a lone surrogate escape at byte #{at}"}) end
    {code, rest} = hex4(text, rest)

    {code, rest} =
      case {code, rest} do
        {high, "\\u" <> tail} when high in 0xD800..0xDBFF ->
          case hex4(text, tail) do
            {low, tail} when low in 0xDC00..0xDFFF ->
              {0x10000 + Bitwise.bsl(high - 0xD800, 10) + (low - 0xDC00), tail}

            _ ->
              lone.()
          end

        other ->
          other
      end

    if code in 0xD800..0xDFFF, do: lone.()
    string(text, rest, [acc, <<code::utf8>>])
  end

  defp hex4(text, rest) do
    case rest do
      <<digits::binary-size(4), tail::binary>> ->
        if hex?(digits),
          do: {String.to_integer(digits, 16), tail},
          else: throw({:fail, unexpected(text, rest)})

      _ ->
        throw({:fail, unexpected(text, rest)})
    end
  end

  defp hex?(digits),
    do:
      for(<<b <- digits>>,
        reduce: true,
        do: (ok -> ok and (b in ?0..?9 or b in ?a..?f or b in ?A..?F))
      )

  defp space(<<b, tail::binary>>) when b in [?\s, ?\t, ?\n, ?\r], do: space(tail)
  defp space(rest), do: rest

  defp unexpected(text, rest) do
    case rest do
      "" ->
        "unexpected end of text"

      <<c::utf8, _::binary>> ->
        "unexpected #{char_debug(c)} at byte #{byte_size(text) - byte_size(rest)}"
    end
  end

  # ---------- coercing ----------

  # `json` as a value of `ty` (TS's `$coerce`), or `throw({:refused, why})`.
  defp coerce(json, ty, at, models) do
    case ty do
      {:named, "Int"} ->
        with {:num, text} <- json, n when is_integer(n) <- integer(text) do
          n
        else
          _ -> expected!("Int", at)
        end

      {:named, "String"} ->
        case json do
          {:str, s} -> s
          _ -> expected!("String", at)
        end

      {:named, "Uuid"} ->
        with {:str, s} <- json, true <- uuid?(s) do
          {:uuid, s}
        else
          _ -> expected!("Uuid", at)
        end

      {:named, "Bool"} ->
        if is_boolean(json), do: json, else: expected!("Bool", at)

      {:named, name} ->
        case Map.get(models, name) do
          nil -> refuse!("cannot decode '#{name}' from JSON at #{path(at)}")
          fields -> record(json, name, fields, at, models)
        end

      {:applied, "List", [item]} ->
        case json do
          items when is_list(items) ->
            items
            |> Enum.with_index()
            |> Enum.map(fn {x, i} -> coerce(x, item, [{:index, i} | at], models) end)

          _ ->
            refuse!("expected array at #{path(at)}")
        end

      {:applied, "List", _} ->
        refuse!("expected array at #{path(at)}")

      {:applied, "Option", _} when json == nil ->
        {:var, "Option", "None", []}

      {:applied, "Option", [inner]} ->
        {:var, "Option", "Some", [coerce(json, inner, at, models)]}

      {:applied, "Map", [key, value]} ->
        map(json, key, value, at, models)

      {:applied, name, _} ->
        refuse!("cannot decode '#{name}' from JSON at #{path(at)}")

      {:tuple, types} ->
        case json do
          items when is_list(items) and length(items) == length(types) ->
            items
            |> Enum.zip(types)
            |> Enum.with_index()
            |> Enum.map(fn {{x, t}, i} -> coerce(x, t, [{:item, i} | at], models) end)
            |> List.to_tuple()

          _ ->
            refuse!("expected #{length(types)}-tuple at #{path(at)}")
        end

      _ ->
        refuse!("cannot decode at #{path(at)}")
    end
  end

  defp expected!(name, at), do: refuse!("expected #{name} at #{path(at)}")
  defp refuse!(why), do: throw({:refused, why})

  # A record of `model`: every field present and of its type; fields the
  # model lacks are dropped.
  defp record({:obj, entries}, model, fields, at, models) do
    out =
      for {field, ty, _default} <- fields, into: %{} do
        case Map.fetch(entries, field) do
          {:ok, v} -> {field, coerce(v, ty, [{:field, field} | at], models)}
          :error -> refuse!("missing field '#{field}' at #{path(at)}")
        end
      end

    {:rec, model, out}
  end

  defp record(_, model, _, at, _), do: refuse!("expected object at #{path(at)} for #{model}")

  # A map from a plain JSON object, its entries in their key texts' order
  # (so of two texts reading back to one key, the one sorting last wins).
  defp map({:obj, entries}, key, value, at, models) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {text, v}, out ->
      kat = [{:key, text} | at]

      k =
        try do
          read_key(text, key, kat, models)
        catch
          {:refused, why} -> refuse!(name_the_key(why))
        end

      Map.put(out, k, coerce(v, value, kat, models))
    end)
  end

  defp map(_, _, _, at, _), do: refuse!("expected Map at #{path(at)}")

  defp name_the_key(why) do
    if String.ends_with?(why, " (a map key)"), do: why, else: why <> " (a map key)"
  end

  defp read_key(text, key, at, models) do
    if key in [{:named, "String"}, {:named, "Uuid"}] do
      coerce({:str, text}, key, at, models)
    else
      case document(text) do
        {:ok, json} -> coerce(json, key, at, models)
        {:error, :too_deep} -> refuse!("#{too_deep_text()} at #{path(at)}")
        {:error, _} -> expected!(Format.type(key), at)
      end
    end
  end

  defp uuid?(s),
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, s)

  # The number `text` (JSON's grammar) as an i64, if its exact value is a
  # whole number in range: `1.0`, `1e3` and `-0` are, `1.5`, `1e-400` and
  # `1e19` are not.
  defp integer(text) do
    {negative, unsigned} =
      case text do
        "-" <> rest -> {true, rest}
        _ -> {false, text}
      end

    {mantissa, exponent} =
      case :binary.split(unsigned, ["e", "E"]) do
        [m, e] -> {m, e}
        [m] -> {m, "0"}
      end

    {whole, fraction} =
      case :binary.split(mantissa, ".") do
        [w, f] -> {w, f}
        [w] -> {w, ""}
      end

    digits = String.trim_leading(whole <> fraction, "0")
    significant = String.trim_trailing(digits, "0")

    if significant == "" do
      0
    else
      zeros = byte_size(digits) - byte_size(significant)
      scale = power(exponent) - byte_size(fraction) + zeros

      if scale < 0 or scale > 19 - byte_size(significant) do
        nil
      else
        magnitude = String.to_integer(significant) * Integer.pow(10, scale)
        n = if negative, do: -magnitude, else: magnitude
        if n >= -9_223_372_036_854_775_808 and n <= 9_223_372_036_854_775_807, do: n
      end
    end
  end

  # An exponent's digits, with their sign, saturating far past any Int.
  defp power(exponent) do
    {sign, digits} =
      case exponent do
        "-" <> d -> {-1, d}
        "+" <> d -> {1, d}
        d -> {1, d}
      end

    # Past 25 digits, an exponent is past any that leaves an i64 whole.
    case String.trim_leading(digits, "0") do
      "" -> 0
      d when byte_size(d) > 25 -> sign * 9_999_999_999_999_999_999_999_999
      d -> sign * String.to_integer(d)
    end
  end

  # ---------- JSON.stringify ----------

  @doc """
  `JSON.stringify(v)`: `Ok` of the text TS writes for data, `Err` of where
  something that is not data is. `type` is the value's type at the call;
  the value's own shape decides how it is written, so it is not needed
  (`nil` is fine). `models` gives a record's field order.
  """
  def stringify(v, _type, models) do
    ok(IO.iodata_to_binary(write(v, [:root], 1, models)))
  catch
    {:refused, why} -> err(why)
  end

  defp write(_v, _at, depth, _models) when depth > @depth_limit,
    do: error!("JSON.stringify: value nested deeper than #{@depth_limit} levels")

  defp write(v, at, depth, models) do
    below = depth + 1

    case v do
      n when is_integer(n) ->
        Integer.to_string(n)

      b when is_boolean(b) ->
        Atom.to_string(b)

      s when is_binary(s) ->
        quote_string(s)

      {:uuid, s} ->
        quote_string(s)

      items when is_list(items) ->
        [
          "[",
          items
          |> Enum.with_index()
          |> Enum.map(fn {x, i} -> write(x, [{:index, i} | at], below, models) end)
          |> commas(),
          "]"
        ]

      map when is_map(map) ->
        entries =
          for {k, x} <- Rt.sorted_entries(map) do
            text = key_text(k, at, below, models)
            [quote_string(text), ":", write(x, [{:key, text} | at], below, models)]
          end

        ["{", commas(entries), "}"]

      {:rec, model, fields} ->
        entries =
          for {field, x} <- field_order(Map.get(models, model, []), fields) do
            [quote_string(field), ":", write(x, [{:field, field} | at], below, models)]
          end

        ["{", commas(entries), "}"]

      {:var, "Option", "Some", [x]} ->
        write(x, at, below, models)

      {:var, "Option", _, _} ->
        "null"

      {:var, "Html", _, _} ->
        refuse!("cannot encode Html as JSON at #{path(at)}")

      {:var, owner, variant, args} ->
        vat = [{:field, "values"} | at]

        values =
          args
          |> Enum.with_index()
          |> Enum.map(fn {x, i} -> write(x, [{:index, i} | vat], below, models) end)

        [
          ~s({"$variant":),
          quote_string("#{owner}.#{variant}"),
          ~s(,"values":[),
          commas(values),
          "]}"
        ]

      {:cmd, _} ->
        refuse!("cannot encode a Cmd as JSON at #{path(at)}")

      {:tx, _, _, _} ->
        write(Rt.tx_variant(v), at, depth, models)

      {:tx, _, _, _, _} ->
        write(Rt.tx_variant(v), at, depth, models)

      {:store, _, _} ->
        refuse!("cannot encode a Store as JSON at #{path(at)}")

      f when is_function(f) ->
        refuse!("cannot encode a function as JSON at #{path(at)}")

      tuple when is_tuple(tuple) ->
        items =
          tuple
          |> Tuple.to_list()
          |> Enum.with_index()
          |> Enum.map(fn {x, i} -> write(x, [{:item, i} | at], below, models) end)

        ["[", commas(items), "]"]
    end
  end

  defp commas(parts), do: Enum.intersperse(parts, ",")

  # A key's text: a String or Uuid as itself, any other key as its own
  # compact JSON text.
  defp key_text(s, _at, _depth, _models) when is_binary(s), do: s
  defp key_text({:uuid, s}, _at, _depth, _models), do: s
  defp key_text(k, at, depth, models), do: IO.iodata_to_binary(write(k, at, depth, models))

  # Those the model declares, in its order, then any other, in name order.
  defp field_order(declared, fields) do
    names = Enum.map(declared, &elem(&1, 0))
    in_model = for name <- names, Map.has_key?(fields, name), do: {name, Map.fetch!(fields, name)}
    others = fields |> Map.drop(names) |> Enum.sort()
    in_model ++ others
  end

  # `s` quoted as JS quotes it: `"` and `\` escaped, a control character as
  # its short escape or `\u00xx`, every other character as itself.
  defp quote_string(s), do: [?", escape_string(s, s, 0, 0, []), ?"]

  defp escape_string(<<b, rest::binary>>, s, start, i, acc) do
    case js_escape(b) do
      nil ->
        escape_string(rest, s, start, i + 1, acc)

      short ->
        escape_string(rest, s, i + 1, i + 1, [acc, binary_part(s, start, i - start), short])
    end
  end

  defp escape_string(<<>>, s, start, i, acc), do: [acc, binary_part(s, start, i - start)]

  defp js_escape(?"), do: "\\\""
  defp js_escape(?\\), do: "\\\\"
  defp js_escape(0x08), do: "\\b"
  defp js_escape(0x0C), do: "\\f"
  defp js_escape(?\n), do: "\\n"
  defp js_escape(?\r), do: "\\r"
  defp js_escape(?\t), do: "\\t"

  defp js_escape(b) when b < 0x20,
    do: "\\u00" <> String.downcase(String.pad_leading(Integer.to_string(b, 16), 2, "0"))

  defp js_escape(_), do: nil

  # ---------- paths and Rust's Debug spelling ----------

  # `at` is innermost first: `[:root]`, `{:field, name}`, `{:index, i}`,
  # `{:item, i}`, `{:key, text}`.
  defp path(at), do: at |> Enum.reverse() |> Enum.map(&segment/1) |> IO.iodata_to_binary()

  defp segment(:root), do: "$"
  defp segment({:field, name}), do: [".", name]
  defp segment({:index, i}), do: ["[", Integer.to_string(i), "]"]
  defp segment({:item, i}), do: [".", Integer.to_string(i)]
  defp segment({:key, text}), do: ["[", str_debug(text), "]"]

  # Rust's `{:?}` of a `str`: quoted, `"` `\` and controls escaped.
  defp str_debug(s) do
    inner = for <<c::utf8 <- s>>, do: debug_escape(c, :str)
    IO.iodata_to_binary([?", inner, ?"])
  end

  # Rust's `{:?}` of a `char`: quoted with `'`.
  defp char_debug(c), do: IO.iodata_to_binary([?', debug_escape(c, :char), ?'])

  defp debug_escape(?\t, _), do: "\\t"
  defp debug_escape(?\r, _), do: "\\r"
  defp debug_escape(?\n, _), do: "\\n"
  defp debug_escape(?\\, _), do: "\\\\"
  defp debug_escape(0, _), do: "\\0"
  defp debug_escape(?", :str), do: "\\\""
  defp debug_escape(?', :char), do: "\\'"

  # Not printable (an approximation of Rust's `is_printable`): controls,
  # line and paragraph separators, and format characters such as U+FEFF.
  defp debug_escape(c, _)
       when c < 0x20 or c in 0x7F..0x9F or c in [0xAD, 0x2028, 0x2029, 0xFEFF] or
              c in 0x200B..0x200F or c in 0x202A..0x202E or c in 0x2060..0x2064,
       do: "\\u{" <> String.downcase(Integer.to_string(c, 16)) <> "}"

  defp debug_escape(c, _), do: <<c::utf8>>
end
