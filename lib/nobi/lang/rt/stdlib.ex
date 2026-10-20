defmodule Nobi.Lang.Rt.Stdlib do
  @moduledoc """
  The stdlib's bodies, one public function per stdlib def (ported in
  behaviour from kinoko-next `interp/stdlib.rs`).

  ## Naming

  A def's function is its Nobi name with the dots made underscores, in
  lower case, at the def's arity: `List.map` is `list_map/2`,
  `String.to_int` is `string_to_int/1`, `Option.with_default` is
  `option_with_default/2`, `Cmd.store.insert` is `cmd_store_insert/2`,
  `JSON.parse` is `json_parse/1`, `Tx.insert` is `tx_insert/1`,
  `Map.has_key` is `map_has_key/2`.
  `function_for/1` answers that from a table built at compile time from
  `Nobi.Lang.Types.Stdlib`, so codegen never makes an atom from text.

  Higher-order functions take Erlang funs (closures, `fun mod:dN/K` def
  references, constructor funs).

  ## What a call site needs beyond the table

  Two stdlib defs read the types at their call, which a function applied
  as a value cannot see (Rust: `CallTypes`):

  - `JSON.parse` decodes into its call's target type: a call compiles to
    `Nobi.Lang.Rt.Json.parse(text, target, models)`. `json_parse/1` is
    the function applied as a value, whose answer is always the `Err` Rust
    gives it. Likewise a call of `JSON.stringify` compiles to
    `Rt.Json.stringify(v, type, models)` (the models give a record's field
    order); `json_stringify/1` writes a record's fields in name order.
  - A store form (`Cmd.store.insert/list/get/update/delete`, `Tx.*`,
    `Store.get/list`) works on the stored model the checker settled for it
    (`Nobi.Lang.Types.Store`), which its node carries: codegen builds it
    with that model, called or applied as a value (see
    `Nobi.Lang.Rt`, "Store effects"), and never calls this module's
    function for it. Those functions are the forms without a model: `nil`
    for it, and `Store.get`/`Store.list` an error.

  A string is a sequence of code points: lengths, slices, splits and
  reversals count code points, never bytes or graphemes.

  Rust's step budget is not ported: the BEAM bounds a run by time and heap
  (`Nobi.Exec`).
  """

  import Kernel, except: [map_size: 1]
  import Nobi.Lang.Rt, only: [error!: 1]

  alias Nobi.Lang.Rt
  alias Nobi.Lang.Rt.Json
  alias Nobi.Lang.Types.Stdlib, as: Signatures

  @table (for {name, {:def, params, _, _}} <- Signatures.signatures(), into: %{} do
            fun = name |> String.replace(".", "_") |> String.downcase() |> String.to_atom()
            {name, {__MODULE__, fun, length(params)}}
          end)

  @doc """
  The function a stdlib def's call or reference compiles to:
  `{module, fun, arity}`, or `nil` for a name that is no stdlib def.
  """
  @spec function_for(String.t()) :: {module(), atom(), non_neg_integer()} | nil
  def function_for(name), do: Map.get(@table, name)

  # ---------- values ----------

  defp some(v), do: {:var, "Option", "Some", [v]}
  defp none, do: {:var, "Option", "None", []}

  defp option_of(nil), do: none()
  defp option_of(v), do: some(v)

  # Arguments a checked program never passes.
  defp wrong!(name), do: error!("`#{name}` applied to arguments of the wrong kinds")

  defp truth!(_name, b) when is_boolean(b), do: b
  defp truth!(name, _), do: wrong!(name)

  defp some_of!(_name, {:var, "Option", "Some", [x]}), do: {:some, x}
  defp some_of!(_name, {:var, "Option", "None", []}), do: :none
  defp some_of!(name, _), do: wrong!(name)

  # `n` clamped to `0..len`: what `take` and `drop` count with.
  defp clamp(n, len), do: n |> max(0) |> min(len)

  # ---------- List ----------

  def list_map(xs, f) when is_list(xs), do: Enum.map(xs, f)

  def list_filter(xs, f) when is_list(xs),
    do: Enum.filter(xs, &truth!("List.filter", f.(&1)))

  # One element, where `concat` takes a list.
  def list_append(xs, x) when is_list(xs), do: xs ++ [x]
  def list_concat(xs, ys) when is_list(xs) and is_list(ys), do: xs ++ ys
  def list_length(xs) when is_list(xs), do: length(xs)
  def list_is_empty(xs) when is_list(xs), do: xs == []

  # Left to right, the accumulator the function's second argument.
  def list_foldl(xs, init, f) when is_list(xs),
    do: Enum.reduce(xs, init, fn x, acc -> f.(x, acc) end)

  # Checked, as the evaluator's `+` is.
  def list_sum(xs) when is_list(xs), do: Enum.reduce(xs, 0, &Rt.add(int!("List.sum", &1), &2))

  def list_maximum(xs) when is_list(xs), do: extreme(xs, "List.maximum", &max/2)
  def list_minimum(xs) when is_list(xs), do: extreme(xs, "List.minimum", &min/2)

  defp extreme(xs, name, pick) do
    xs
    |> Enum.reduce(nil, fn x, best ->
      x = int!(name, x)
      if best == nil, do: x, else: pick.(best, x)
    end)
    |> option_of()
  end

  defp int!(_name, n) when is_integer(n), do: n
  defp int!(name, _), do: wrong!(name)

  def list_reverse(xs) when is_list(xs), do: Enum.reverse(xs)

  # By equality, as `==` compares.
  def list_member(xs, y) when is_list(xs), do: Enum.any?(xs, &Rt.eq(&1, y))

  # Up to the element that decides, as JS's `every` and `some`.
  def list_all(xs, f) when is_list(xs), do: Enum.all?(xs, &truth!("List.all", f.(&1)))
  def list_any(xs, f) when is_list(xs), do: Enum.any?(xs, &truth!("List.any", f.(&1)))

  def list_head([]), do: none()
  def list_head([x | _]), do: some(x)

  # Clamped: a count past either end is the whole list or none of it.
  def list_take(xs, n) when is_list(xs) and is_integer(n), do: Enum.take(xs, clamp(n, length(xs)))
  def list_drop(xs, n) when is_list(xs) and is_integer(n), do: Enum.drop(xs, clamp(n, length(xs)))

  def list_filter_map(xs, f) when is_list(xs) do
    Enum.flat_map(xs, fn x ->
      case some_of!("List.filter_map", f.(x)) do
        {:some, y} -> [y]
        :none -> []
      end
    end)
  end

  # Ascending by an `Int` key and stable; each key computed once, in order.
  def list_sort_by(xs, f) when is_list(xs) do
    xs
    |> Enum.map(&{int!("List.sort_by", f.(&1)), &1})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # ---------- String ----------

  # Code points (Rust's `chars().count()`), not graphemes, counted without
  # building a charlist.
  def string_length(s) when is_binary(s), do: code_points(s, 0)

  defp code_points(<<_::utf8, rest::binary>>, n), do: code_points(rest, n + 1)
  defp code_points(<<>>, n), do: n
  def string_concat(a, b) when is_binary(a) and is_binary(b), do: a <> b
  def string_from_int(n) when is_integer(n), do: Integer.to_string(n)

  @doc """
  Strict decimal: an optional `-` and ASCII digits, nothing else, of at
  most `Rt.max_int_digits/0` significant digits.
  """
  def string_to_int(s) when is_binary(s) do
    {sign, digits} =
      case s do
        "-" <> rest -> {-1, rest}
        _ -> {1, s}
      end

    with true <- digits != "" and ascii_digits?(digits),
         significant = without_leading_zeros(digits),
         true <- byte_size(significant) <= Rt.max_int_digits() do
      some(sign * parse_digits(significant))
    else
      _ -> none()
    end
  end

  defp without_leading_zeros("0" <> rest), do: without_leading_zeros(rest)
  defp without_leading_zeros(digits), do: digits

  defp parse_digits(""), do: 0
  defp parse_digits(digits), do: String.to_integer(digits)

  defp ascii_digits?(s), do: for(<<b <- s>>, reduce: true, do: (ok -> ok and b in ?0..?9))

  def string_is_empty(s) when is_binary(s), do: s == ""

  def string_reverse(s) when is_binary(s),
    do: s |> String.to_charlist() |> Enum.reverse() |> List.to_string()

  # Rust's `char::is_whitespace`: Unicode's White_Space property.
  @whitespace [?\t, ?\n, 0x0B, 0x0C, ?\r, ?\s, 0x85, 0xA0, 0x1680] ++
                Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

  def string_trim(s) when is_binary(s) do
    s
    |> String.to_charlist()
    |> Enum.drop_while(&(&1 in @whitespace))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in @whitespace))
    |> Enum.reverse()
    |> List.to_string()
  end

  def string_to_upper(s) when is_binary(s), do: String.upcase(s)

  @doc """
  Rust's `to_lowercase`: Unicode's full lower-case mapping, with a capital
  sigma at the end of a word written `ς`.
  """
  def string_to_lower(s) when is_binary(s) do
    if String.contains?(s, "Σ"), do: lower_with_sigma(s), else: String.downcase(s)
  end

  # Rust's `map_uppercase_sigma`: final when a cased letter comes before it
  # and none after it, skipping case-ignorable characters either way.
  defp lower_with_sigma(s) do
    chars = String.to_charlist(s)

    chars
    |> Enum.with_index()
    |> Enum.map(fn
      {?Σ, i} ->
        before = chars |> Enum.take(i) |> Enum.reverse()
        rest = Enum.drop(chars, i + 1)
        if cased_next?(before) and not cased_next?(rest), do: "ς", else: "σ"

      {c, _} ->
        String.downcase(<<c::utf8>>)
    end)
    |> IO.iodata_to_binary()
  end

  defp cased_next?(chars) do
    case Enum.drop_while(chars, &case_ignorable?/1) do
      [c | _] -> cased?(c)
      [] -> false
    end
  end

  # Approximations of Unicode's Cased and Case_Ignorable properties: a
  # character that changes case is cased; apostrophes, stops, colons, the
  # soft hyphen and combining marks are case-ignorable.
  defp cased?(c) do
    s = <<c::utf8>>
    String.downcase(s) != s or String.upcase(s) != s
  end

  defp case_ignorable?(c),
    do: c in [?', ?., ?:, ?^, ?`, 0xAD, 0xB7, 0x2019] or c in 0x0300..0x036F

  def string_contains(s, sub) when is_binary(s) and is_binary(sub), do: String.contains?(s, sub)

  def string_starts_with(s, prefix) when is_binary(s) and is_binary(prefix),
    do: String.starts_with?(s, prefix)

  @doc "The pieces between separators, as JS's `split`; an empty separator splits into code points."
  def string_split(s, "") when is_binary(s), do: for(<<c::utf8 <- s>>, do: <<c::utf8>>)

  def string_split(s, sep) when is_binary(s) and is_binary(sep),
    do: :binary.split(s, sep, [:global])

  def string_join(parts, sep) when is_list(parts) and is_binary(sep) do
    Enum.each(parts, fn p -> is_binary(p) or wrong!("String.join") end)
    Enum.join(parts, sep)
  end

  @doc """
  The code points from `from` up to `to`, as TS's
  `[...s].slice(from < 0 ? 0 : from, to)`: a negative start is the start, a
  negative end counts back from the end, and both stop at the ends.
  """
  def string_slice(s, from, to) when is_binary(s) and is_integer(from) and is_integer(to) do
    chars = String.to_charlist(s)
    len = length(chars)
    start = from |> max(0) |> min(len)
    stop = if to < 0, do: max(len + to, 0), else: min(to, len)

    if start >= stop,
      do: "",
      else: chars |> Enum.slice(start, stop - start) |> List.to_string()
  end

  # ---------- Option ----------

  def option_with_default(o, default) do
    case some_of!("Option.with_default", o) do
      {:some, x} -> x
      :none -> default
    end
  end

  def option_map(o, f) do
    case some_of!("Option.map", o) do
      {:some, x} -> some(f.(x))
      :none -> none()
    end
  end

  def option_and_then(o, f) do
    case some_of!("Option.and_then", o) do
      {:some, x} -> f.(x)
      :none -> none()
    end
  end

  # ---------- Map ----------

  # Every path that hashes a key charges it first, as a map literal's keys
  # are (`Rt.charge_insertion/2`): Erlang hashes a key in a BIF that never
  # yields, so a key too heavy to walk is the step-budget error instead. A
  # lookup compares with as many keys as an insertion would.
  defp charged(m, key) when is_map(m) do
    Rt.charge_insertion(key, Kernel.map_size(m))
    key
  end

  def map_get(m, key) when is_map(m) do
    case Map.fetch(m, charged(m, key)) do
      {:ok, v} -> some(v)
      :error -> none()
    end
  end

  def map_put(m, key, v) when is_map(m), do: Map.put(m, charged(m, key), v)
  def map_delete(m, key) when is_map(m), do: Map.delete(m, charged(m, key))
  def map_has_key(m, key) when is_map(m), do: Map.has_key?(m, charged(m, key))
  def map_size(m) when is_map(m), do: Kernel.map_size(m)

  # In Nobi key order (`Rt.sorted_entries/1`), as `show` and JSON write a map.
  def map_keys(m) when is_map(m), do: for({k, _} <- Rt.sorted_entries(m), do: k)
  def map_values(m) when is_map(m), do: for({_, v} <- Rt.sorted_entries(m), do: v)
  def map_to_list(m) when is_map(m), do: Rt.sorted_entries(m)

  @doc "A map of the pairs, a later key's value replacing an earlier one's."
  def map_from_list(pairs) when is_list(pairs) do
    Enum.each(pairs, fn p -> match?({_, _}, p) or wrong!("Map.from_list") end)
    Rt.map_from_list(pairs)
  end

  # ---------- JSON, applied as values ----------

  @doc "`JSON.parse` applied as a value: no type to decode into, so always `Err`."
  def json_parse(text) when is_binary(text), do: Json.parse(text, nil, %{})

  @doc "`JSON.stringify` applied as a value: a record's fields in name order."
  def json_stringify(v), do: Json.stringify(v, nil, %{})

  # ---------- Cmd and Tx ----------

  def cmd_none, do: Rt.cmd_none()
  def cmd_batch(cmds), do: Rt.cmd_batch(cmds)

  @effects for {name, {:def, params, _, _}} <- Signatures.signatures(),
               String.starts_with?(name, "Cmd."),
               name not in ["Cmd.none", "Cmd.batch"],
               do: {name, length(params)}

  for {name, arity} <- @effects do
    fun = name |> String.replace(".", "_") |> String.downcase() |> String.to_atom()
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc "`#{name}`: the effect, its arguments in order (a store effect's model `nil`)."
    def unquote(fun)(unquote_splicing(args)),
      do: Rt.cmd_effect(unquote(name), nil, unquote(args))
  end

  @doc "`Tx.insert(row)` without its model (`Nobi.Lang.Rt`'s Tx.Op)."
  def tx_insert(row), do: {:tx, :insert, nil, row}
  @doc "`Tx.update(id, row)` without its model."
  def tx_update(id, row), do: {:tx, :update, nil, id, row}
  @doc "`Tx.delete(Model, id)`: the model's name (a binary), then the id."
  def tx_delete(model, id) when is_binary(model), do: {:tx, :delete, model, id}

  # ---------- Store (reads inside a transaction) ----------

  @store_why "reads the model its result is used at; it is compiled with it (`Nobi.Data.Hooks`)"

  @doc "`Store.get` without its model: an error."
  def store_get(_store, _id), do: error!("`Store.get` " <> @store_why)

  @doc "`Store.list` without its model: an error."
  def store_list(_store), do: error!("`Store.list` " <> @store_why)

  # ---------- Uuid ----------

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "The canonical lowercase text of a Uuid, as a route URL carries it."
  def uuid_to_string({:uuid, s}) when is_binary(s), do: s
  def uuid_to_string(_), do: wrong!("Uuid.to_string")

  @doc "`Option.Some(uuid)` for a UUID in any case (kept lowercase), else `Option.None`."
  def uuid_parse(s) when is_binary(s) do
    down = String.downcase(s)
    if Regex.match?(@uuid, down), do: some({:uuid, down}), else: none()
  end

  def uuid_parse(_), do: wrong!("Uuid.parse")
end
