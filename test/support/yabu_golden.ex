defmodule YabuGolden do
  @moduledoc """
  The TS/Rust *eval* goldens (`calls`, `traces`, `tests`, `stdlib.json`) and the
  decoder that turns TS's JSON value shape into the BEAM representation of the
  codegen spec (ported from `kinoko-next/crates/yabu/tests/oracle/decode.rs`).

  Decoding is directed by the declared type, from the program's signatures
  (`signatures/1`): a bare JSON string is a `Uuid` or a `String` as the type
  says, never as it looks.

  ## TS JSON shape

  `{"$tup": [..]}` tuple; `{"$t": M, ..fields}` record of model `M` (no `id`
  when built in memory); `{"$v": "T.V", "a": [..]}` variant of `T`;
  `{"$map": [[k, v], ..]}` map (a repeated key keeps its last value, Rust's
  rule); `{"$c": ..}` a Cmd; `{"$h": tag, "at": [[name, v], ..], "ch": [..]}` an
  Html element; `{"$fn": name}` a function value.

  ## BEAM representation (what Rt/codegen must produce)

  | Yabu | BEAM |
  |---|---|
  | Int / String / Bool | integer / binary / boolean |
  | Unit, tuple | `{}` / tuple |
  | Uuid | `{:uuid, binary}` |
  | List / Map | list / Erlang map |
  | record | `{:rec, "Model.Name", %{"field" => v}}` |
  | variant | `{:var, "Owner", "Variant", [args]}` |
  | Html | `{:var, "Html", "Element", [tag, [{name, value}], [children]]}` and `{:var, "Html", "Text", [text]}` |
  | Cmd | `{:cmd, :none}`, `{:cmd, {:batch, [cmd]}}`, `{:cmd, {:effect, "Cmd.store.insert", model_or_nil, [args]}}` |

  Html follows `Value::html_element` in `value.rs`: each attribute is a
  `{name, value}` tuple (`{"on-click", msg}` for an event; a plain attribute is
  a binary, integer or boolean); children are Html values, with nested child
  lists spliced flat and a raw child written as text (a string as itself, an
  Int as its digits, a Bool as `"true"`/`"false"`). An effect's `model` is the
  model name only for a store read (`store.list`), else `nil`.

  ## Functions in decoded values

  A real function is an Erlang fun, which a decoder cannot build without an
  image. So decoded function values are markers: `lambda/0` (`{:fn, "<lambda>"}`)
  for a compiled callback, `{:def_ref, name}` for a def and
  `{:ctor_ref, owner, variant, arity}` for a constructor. `without_closures/1`
  rewrites every closure in an actual result to `lambda/0` and every def or
  constructor value to its marker, so a result can be compared with a golden
  answer (closures never compare equal).
  """

  alias Kinoko.Lang
  alias Kinoko.Lang.Types.{Extract, Stdlib}

  @dir Path.expand("../fixtures/yabu/eval", __DIR__)
  @lambda_name "<lambda>"

  @effects %{
    "store.insert" => {["value", "cb"], false},
    "store.list" => {["cb"], true}
  }

  # --- loaders -------------------------------------------------------------

  @doc "`[%{\"file\", \"calls\", \"traces\", \"tests\"}]`."
  def corpus, do: read("corpus.json")

  @doc "`[%{\"seed\", \"source\", \"calls\", \"traces\"}]`, sources migrated to typed Html."
  def generated, do: read("generated.json")

  @doc "`[%{\"name\", \"examples\"}]`."
  def stdlib, do: read("stdlib.json")

  defp read(file), do: @dir |> Path.join(file) |> File.read!() |> JSON.decode!()

  @doc "The stdlib's signatures plus the program `source`'s (name => signature)."
  def signatures(source) do
    {:ok, decls} = Lang.parse(source)

    Enum.reduce(decls, Stdlib.signatures(), fn decl, acc ->
      Map.put(acc, Kinoko.Lang.Ast.name(decl), Extract.signature(decl))
    end)
  end

  @doc "A def's declared `{params, ret}`."
  def def_signature(sigs, name) do
    case Map.get(sigs, name) do
      {:def, params, ret} -> {params, ret}
      other -> raise "`#{name}` is no def of the program: #{inspect(other)}"
    end
  end

  # --- closure marker --------------------------------------------------------

  @doc "The marker a closure is compared as."
  def lambda, do: {:fn, @lambda_name}

  @doc """
  `term` with every closure in it, however deep, written as `lambda/0`, and
  every def or constructor taken as a value written as the decoder's marker
  for it (`{:def_ref, name}`, `{:ctor_ref, owner, variant, arity}`), as Rust's
  `without_closures` keeps a def or a constructor and replaces only closures.
  """
  def without_closures(f) when is_function(f) do
    info = Function.info(f)

    cond do
      # an image def or a stdlib def, named as `Show` names it
      info[:type] == :external ->
        case Kinoko.Exec.Show.show(f) do
          "<fn " <> named -> {:def_ref, String.trim_trailing(named, ">")}
          _ -> lambda()
        end

      # `Rt.ctor/3`'s fun only builds the variant: applied to placeholders
      # it names it
      info[:module] == Kinoko.Lang.Rt and
          String.starts_with?(Atom.to_string(info[:name]), "-ctor/3-") ->
        {:var, owner, variant, _} = apply(f, List.duplicate(nil, info[:arity]))
        {:ctor_ref, owner, variant, info[:arity]}

      true ->
        lambda()
    end
  end

  def without_closures(list) when is_list(list), do: Enum.map(list, &without_closures/1)

  # a map's keys are data (the checker refuses the rest), so stay as they are
  def without_closures(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, without_closures(v)} end)

  def without_closures(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&without_closures/1) |> List.to_tuple()

  def without_closures(x), do: x

  # --- decoder -----------------------------------------------------------------

  @doc "`json` as a value of `type`, from `sigs`: `{:ok, term}` or `{:error, why}`."
  def decode(json, type, sigs) do
    value(json, type, sigs)
  catch
    {:decode, why} -> {:error, why}
  else
    v -> {:ok, v}
  end

  defp value(json, type, sigs) do
    case type do
      {:named, "Int"} when is_integer(json) -> json
      {:named, "Int"} -> not_a("an Int", json)
      {:named, "String"} when is_binary(json) -> json
      {:named, "String"} -> not_a("a String", json)
      {:named, "Bool"} when is_boolean(json) -> json
      {:named, "Bool"} -> not_a("a Bool", json)
      {:named, "Uuid"} -> uuid(json)
      {:named, "Unit"} -> if is_nil(json), do: {}, else: not_a("Unit", json)
      {:named, name} -> named(json, name, [], sigs)
      {:applied, "List", [item]} -> list(json, item, sigs)
      {:applied, "Map", [k, v]} -> map(json, k, v, sigs)
      {:applied, "Cmd", [_]} -> {:cmd, cmd(json, sigs)}
      {:applied, "Html", [_]} -> html(json, sigs)
      {:applied, name, args} -> named(json, name, args, sigs)
      {:tuple, items} -> tuple(json, items, sigs)
      {:arrow, _, _} -> function(json, sigs)
      {:var, v} -> fail("no type to decode #{inspect(json)} by: `#{v}` is a type variable")
    end
  end

  defp uuid(json) do
    if is_binary(json) and
         Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, json),
       do: {:uuid, json},
       else: not_a("a Uuid", json)
  end

  defp list(json, item, sigs) when is_list(json), do: Enum.map(json, &value(&1, item, sigs))
  defp list(json, _, _), do: not_a("a List", json)

  defp tuple(json, items, sigs) do
    case only(json, "$tup") do
      parts when is_list(parts) and length(parts) == length(items) ->
        parts
        |> Enum.zip(items)
        |> Enum.map(fn {x, t} -> value(x, t, sigs) end)
        |> List.to_tuple()

      _ ->
        not_a("a tuple of #{length(items)}", json)
    end
  end

  defp map(json, kt, vt, sigs) do
    case only(json, "$map") do
      pairs when is_list(pairs) ->
        Map.new(pairs, fn
          [k, v] -> {value(k, kt, sigs), value(v, vt, sigs)}
          other -> not_a("a key and a value", other)
        end)

      _ ->
        not_a("a Map", json)
    end
  end

  defp named(json, name, args, sigs) do
    case Map.get(sigs, name) do
      {:model, fields} -> record(json, name, fields, sigs)
      {:type, params, variants} -> variant(json, name, params, variants, args, sigs)
      _ -> fail("`#{name}` is no model or type of the program, so #{inspect(json)} has no type")
    end
  end

  defp record(%{"$t" => model} = json, model, fields, sigs) do
    out =
      for {field, x} <- json, field != "$t", into: %{} do
        case List.keyfind(fields, field, 0) do
          {_, ty} -> {field, value(x, ty, sigs)}
          nil -> fail("a `#{model}` has no field `#{field}`: #{inspect(json)}")
        end
      end

    {:rec, model, out}
  end

  defp record(json, model, _, _), do: not_a("a `#{model}`", json)

  defp variant(%{"$v" => full, "a" => values} = json, owner, params, variants, args, sigs)
       when map_size(json) == 2 and is_binary(full) and is_list(values) do
    prefix = owner <> "."

    declared =
      if String.starts_with?(full, prefix),
        do: List.keyfind(variants, String.replace_prefix(full, prefix, ""), 0)

    case declared do
      {name, tys} when length(tys) == length(values) ->
        vals =
          values
          |> Enum.zip(tys)
          |> Enum.map(fn {x, t} -> value(x, substitute(t, params, args), sigs) end)

        {:var, owner, name, vals}

      {name, tys} ->
        not_a("`#{owner}.#{name}` with #{length(tys)} argument(s)", json)

      nil ->
        not_a("a `#{owner}`", json)
    end
  end

  defp variant(json, owner, _, _, _, _), do: not_a("a `#{owner}`", json)

  # A def or a constructor, by what the program declares the name to be.
  defp function(json, sigs) do
    case only(json, "$fn") do
      @lambda_name ->
        lambda()

      name when is_binary(name) ->
        case Map.get(sigs, name) do
          {:def, _, _} -> {:def_ref, name}
          _ -> ctor(name, sigs)
        end

      _ ->
        not_a("a function", json)
    end
  end

  defp ctor(name, sigs) do
    with [_ | _] = parts <- String.split(name, "."),
         owner = parts |> Enum.drop(-1) |> Enum.join("."),
         variant = List.last(parts),
         {:type, _, variants} <- Map.get(sigs, owner),
         {_, tys} <- List.keyfind(variants, variant, 0) do
      {:ctor_ref, owner, variant, length(tys)}
    else
      _ -> fail("`#{name}` is no def or constructor of the program")
    end
  end

  defp cmd(%{"$c" => "none"} = json, _) when map_size(json) == 1, do: :none
  defp cmd(%{"$c" => "none"} = json, _), do: not_a("`Cmd.none()`", json)

  defp cmd(%{"$c" => "batch", "cmds" => cmds} = json, sigs)
       when map_size(json) == 2 and is_list(cmds),
       do: {:batch, Enum.map(cmds, &cmd(&1, sigs))}

  defp cmd(%{"$c" => "batch"} = json, _), do: not_a("a batch", json)
  defp cmd(%{"$c" => tag} = json, sigs) when is_binary(tag), do: effect(tag, json, sigs)
  defp cmd(json, _), do: not_a("a Cmd", json)

  # TS writes an effect's arguments as named payload fields, and beside them
  # the model the store reads or writes. Rust's (and our) effect is the call
  # with its arguments; the model is kept only for a store read.
  defp effect(tag, json, sigs) do
    {fields, read?} =
      Map.get(@effects, tag) || fail("no decoding for the effect `#{tag}`: #{inspect(json)}")

    name = "Cmd." <> tag
    {params, _} = def_signature(sigs, name)

    model =
      with true <- map_size(json) == length(fields) + 2,
           m when is_binary(m) <- json["model"],
           do: m

    unless is_binary(model), do: not_a("`#{name}`'s fields #{inspect(fields)} and a model", json)

    args =
      fields
      |> Enum.zip(params)
      |> Enum.map(fn {field, ty} ->
        x =
          case Map.fetch(json, field) do
            {:ok, x} -> x
            :error -> not_a("`#{name}` with `#{field}`", json)
          end

        value(x, substitute(ty, ["a"], [{:named, model}]), sigs)
      end)

    {:effect, name, if(read?, do: model), args}
  end

  defp html(%{"$h" => tag, "at" => attrs, "ch" => children} = json, sigs)
       when map_size(json) == 3 and is_binary(tag) and is_list(attrs) and is_list(children) do
    pairs =
      Enum.map(attrs, fn
        [name, v] when is_binary(name) -> {name, attribute(v, sigs)}
        other -> not_a("an attribute", other)
      end)

    {:var, "Html", "Element", [tag, pairs, Enum.flat_map(children, &child(&1, sigs))]}
  end

  defp html(json, _), do: not_a("Html", json)

  # An attribute's value: its shape says which type.
  defp attribute(json, _) when is_binary(json) or is_integer(json) or is_boolean(json), do: json
  defp attribute(%{"$fn" => _} = json, sigs), do: function(json, sigs)

  defp attribute(%{"$v" => full} = json, sigs) when is_binary(full) do
    case String.split(full, ".") do
      [_, _ | _] = parts -> named(json, parts |> Enum.drop(-1) |> Enum.join("."), [], sigs)
      _ -> not_a("an attribute's value", json)
    end
  end

  defp attribute(json, _), do: not_a("an attribute's value", json)

  # A child, as Rust's evaluator writes it: an element as itself, a nested list
  # spliced, a raw value as text.
  defp child(items, sigs) when is_list(items), do: Enum.flat_map(items, &child(&1, sigs))
  defp child(s, _) when is_binary(s), do: [{:var, "Html", "Text", [s]}]
  defp child(n, _) when is_integer(n), do: [{:var, "Html", "Text", [Integer.to_string(n)]}]
  defp child(b, _) when is_boolean(b), do: [{:var, "Html", "Text", [Atom.to_string(b)]}]
  defp child(json, sigs), do: [html(json, sigs)]

  defp substitute({kind, name} = t, params, args) when kind in [:named, :var] do
    case Enum.find_index(params, &(&1 == name)) do
      nil -> t
      i -> Enum.at(args, i, t)
    end
  end

  defp substitute({:applied, n, ts}, ps, as),
    do: {:applied, n, Enum.map(ts, &substitute(&1, ps, as))}

  defp substitute({:tuple, ts}, ps, as), do: {:tuple, Enum.map(ts, &substitute(&1, ps, as))}

  defp substitute({:arrow, ts, r}, ps, as),
    do: {:arrow, Enum.map(ts, &substitute(&1, ps, as)), substitute(r, ps, as)}

  defp only(%{} = json, tag) when map_size(json) == 1, do: Map.get(json, tag)
  defp only(_, _), do: nil

  defp not_a(what, json), do: fail("expected #{what}, got #{inspect(json)}")
  defp fail(why), do: throw({:decode, why})
end
