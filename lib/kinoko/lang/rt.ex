defmodule Kinoko.Lang.Rt do
  @moduledoc """
  Runtime support for Yabu compiled to Erlang: what generated code calls
  besides plain Erlang. Ported in behaviour from kinoko-next
  `interp/value.rs` and `interp/eval.rs`. Pure: no processes, IO or
  process dictionary.

  ## Values (BEAM terms)

  | Yabu | BEAM |
  |---|---|
  | Int / String / Bool | integer (i64, checked) / UTF-8 binary / boolean |
  | Unit, tuple | `{}` / tuple |
  | Uuid | `{:uuid, binary}` |
  | List / Map | list / Erlang map |
  | record | `{:rec, "Model.Name", %{"field" => v}}` |
  | variant | `{:var, "Owner", "Variant", [args]}` (`Option`, `Result`, `Html`, `Tx` too) |
  | function | Erlang fun |
  | Cmd | `{:cmd, :none}`, `{:cmd, {:batch, [bare]}}`, `{:cmd, {:effect, name, model \\| nil, [args]}}` |

  `Cmd.navigate(App, args…)` is `{:cmd, {:effect, "Cmd.navigate", nil,
  [app | args]}}`: the target app's name (a binary) followed by `init`'s
  arguments positionally. The host turns it into a URL with
  `Kinoko.Lang.Routes.path/3`.

  A batch holds its commands *bare*: `:none`, `{:batch, _}` or
  `{:effect, ...}`, never re-wrapped in `{:cmd, _}`.

  A Yabu tuple is never mistaken for a record, variant, Uuid or Cmd: those
  tag their first element with an atom that no Yabu value is.

  ## Errors

  A runtime error is `throw({:yabu_error, message})`, worded as Rust's
  `EvalError` words it: `"integer overflow"`, `"division by zero"`,
  `"no case arm matched"`, ...

  ## Equality and order

  `eq/2` is `===` (Erlang `=:=`): structural, a map's order ignored. It,
  `compare/2` and a map literal's keys (`map_from_list/1`) are charged by
  weight first (see "the walk budget" below): past a million steps they
  throw Rust's `"evaluation took more than 1000000 steps"`. Functions
  compare by `fun_eq/2`, as Rust's `Function` equality: a closure equals
  nothing (not even itself), a def taken as a value equals only the same
  def, a constructor only the same constructor; a closure's environment is
  never compared.

  `compare/2` is Rust's `Value` `Ord`: first by kind (Int, String, Bool,
  Uuid, List, Map, tuple, record, variant, function, Cmd), then
  structurally. Functions order as Rust's do, read without their
  environment (`fun_order`): closures first (by their code's identity),
  then defs, then constructors, each by name.
  """

  import Kernel, except: [div: 2]

  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807

  @type value :: term()

  # The walk budget (see "the walk budget" below).
  @budget 1_000_000
  @bytes_per_step 64

  defguardp is_i64(n) when is_integer(n) and n >= @i64_min and n <= @i64_max

  # ---------- errors ----------

  @doc "Stops evaluation with a Yabu runtime error."
  @spec error!(String.t()) :: no_return()
  def error!(message), do: throw({:yabu_error, message})

  # ---------- arithmetic ----------

  @doc "Checked i64 `a + b`."
  def add(a, b), do: checked(a + b)

  @doc "Checked i64 `a - b`."
  def sub(a, b), do: checked(a - b)

  @doc "Checked i64 `a * b`."
  def mul(a, b), do: checked(a * b)

  @doc "Checked i64 `a / b`, truncating toward zero; `b == 0` is an error."
  def div(_a, 0), do: error!("division by zero")
  def div(a, b), do: checked(Kernel.div(a, b))

  @doc "Checked i64 `-a`."
  def neg(a), do: checked(-a)

  @doc "`n` if it is an i64, else the overflow error (an Int literal's check)."
  def checked(n) when is_i64(n), do: n
  def checked(_), do: error!("integer overflow")

  @doc "`a ++ b` on strings."
  def concat(a, b) when is_binary(a) and is_binary(b), do: a <> b

  # ---------- equality and order ----------

  @doc """
  Yabu `==`: structural, within the walk budget (`charge_comparison/2`),
  with Rust's rule for functions (`fun_eq/2`). Values holding no function
  compare with `=:=`; any other pair is walked in ordinary code, so `=:=`
  never meets a closure (it would compare captured environments, however
  large, without yielding).
  """
  def eq(a, b) when is_number(a) or is_atom(a) or is_number(b) or is_atom(b), do: a === b
  def eq(a, b) when is_binary(a) and is_binary(b), do: a === b
  def eq({:uuid, a}, {:uuid, b}), do: a === b
  def eq(a, b) when is_function(a) and is_function(b), do: fun_eq(a, b)

  def eq(a, b) do
    {wa, fa} = scan(a, @budget + 1)
    {wb, fb} = scan(b, @budget + 1)
    if min(wa, wb) > @budget, do: out_of_steps!()

    # A scan cut short at the budget may have missed a function.
    if fa or fb or max(wa, wb) > @budget,
      do: deep_eq([{a, b}]),
      else: a === b
  end

  # Pairs to compare, walked side by side: never deeper into either than the
  # other goes, so no further than the lighter one's weight.
  defp deep_eq([]), do: true

  defp deep_eq([{a, b} | rest]) do
    case {a, b} do
      {f, g} when is_function(f) and is_function(g) ->
        fun_eq(f, g) and deep_eq(rest)

      {f, g} when is_function(f) or is_function(g) ->
        false

      {[x | xs], [y | ys]} ->
        deep_eq([{x, y}, {xs, ys} | rest])

      {l, m} when is_list(l) and is_list(m) ->
        l === m and deep_eq(rest)

      {m, n} when is_map(m) and is_map(n) ->
        map_size(m) == map_size(n) and deep_eq_entries(:maps.next(:maps.iterator(m)), n, rest)

      {t, u} when is_tuple(t) and is_tuple(u) ->
        tuple_size(t) == tuple_size(u) and
          deep_eq(Enum.zip(Tuple.to_list(t), Tuple.to_list(u)) ++ rest)

      _ ->
        a === b and deep_eq(rest)
    end
  end

  # A map's keys never hold functions (the checker keeps them out) and were
  # charged when inserted, so looking one up is cheap.
  defp deep_eq_entries(:none, _n, rest), do: deep_eq(rest)

  defp deep_eq_entries({k, v, it}, n, rest) do
    case n do
      %{^k => w} -> deep_eq_entries(:maps.next(it), n, [{v, w} | rest])
      _ -> false
    end
  end

  @doc """
  Rust's `Function` equality: a closure equals nothing, not even itself; a
  def taken as a value (an external fun, `fun Mod:dN/K` or a stdlib
  function) equals only the same def; a constructor taken as a value
  (`ctor/3`'s fun) equals only the same constructor. Never compares a
  closure's environment.

  A constructor of more than 8 arguments taken as a value is built inline
  by codegen, as a closure, so it equals nothing.
  """
  @spec fun_eq(fun(), fun()) :: boolean()
  def fun_eq(f, g) do
    case {fun_key(f), fun_key(g)} do
      {{:closure, _, _, _}, _} -> false
      {_, {:closure, _, _, _}} -> false
      {k, k} -> true
      _ -> false
    end
  end

  # What a function is, read without its environment: `{:def, m, f, a}`,
  # `{:ctor, owner, variant, arity}` or `{:closure, m, index, uniq}`.
  defp fun_key(f) do
    info = Function.info(f)

    cond do
      info[:type] == :external ->
        {:def, info[:module], info[:name], info[:arity]}

      ctor_fun?(info) ->
        # It only builds the variant: applied to placeholders it names it.
        {:var, owner, variant, _} = apply(f, List.duplicate(nil, info[:arity]))
        {:ctor, owner, variant, info[:arity]}

      true ->
        {:closure, info[:module], info[:new_index], info[:new_uniq]}
    end
  end

  defp ctor_fun?(info),
    do:
      info[:module] == __MODULE__ and String.starts_with?(Atom.to_string(info[:name]), "-ctor/3-")

  @doc "Rust's `Value` `Ord`: `:lt`, `:eq` or `:gt`, within the walk budget."
  @spec compare(value, value) :: :lt | :eq | :gt
  def compare(a, b) do
    charge_comparison(a, b)
    cmp(a, b)
  end

  @doc "`compare(a, b) != :gt`: a sorter for `Enum.sort/2`."
  def le(a, b), do: compare(a, b) != :gt

  @doc """
  A map's entries in Yabu key order (`compare/2`). All-Int and all-String
  keys order the same in Yabu and in Erlang's term order, so a plain sort
  serves (native and uncharged, bounded by the key's size); only other
  keys take the charged comparator.
  """
  def sorted_entries(map) when is_map(map) do
    pairs = Map.to_list(map)

    if Enum.all?(pairs, fn {k, _} -> is_integer(k) end) or
         Enum.all?(pairs, fn {k, _} -> is_binary(k) end),
       do: Enum.sort(pairs),
       else: Enum.sort(pairs, fn {a, _}, {b, _} -> le(a, b) end)
  end

  # Within a comparison already charged.
  defp sorted(map),
    do: map |> Map.to_list() |> Enum.sort(fn {a, _}, {b, _} -> cmp(a, b) != :gt end)

  defp cmp(a, b) do
    case {kind(a), kind(b)} do
      {k, k} -> same_kind(k, a, b)
      {k, j} when k < j -> :lt
      _ -> :gt
    end
  end

  # ---------- the walk budget ----------

  # Comparing two values, hashing a map key and handing a result back walk
  # them whole, however much of them is shared: `x40 = [x39, x39]` is forty
  # nodes in memory and 2^40 to walk. Erlang's `=:=` and map hashing are
  # BIFs that never yield, so a walk that long would hold a scheduler past
  # any timeout. As Rust charges such a walk by the value's weight
  # (`program.rs`'s `weight`, `eval.rs`'s `charge_comparison`), so does this:
  # a walk past `step_budget/0` steps is an error, found by a preemptible
  # walk that stops at the budget.

  @doc "The most steps one walk may take (Rust's `STEP_BUDGET`)."
  def step_budget, do: @budget

  @doc "Rust's error for a walk past the budget."
  @spec out_of_steps!() :: no_return()
  def out_of_steps!, do: error!("evaluation took more than #{@budget} steps")

  @doc """
  Throws `out_of_steps!/0` when comparing `a` with `b` would walk more than
  the budget: at most the lighter one's weight, as Rust charges it.
  """
  @spec charge_comparison(value, value) :: :ok
  def charge_comparison(a, b) do
    if weight(b, weight(a, @budget + 1)) > @budget, do: out_of_steps!(), else: :ok
  end

  @doc """
  Throws `out_of_steps!/0` when inserting `key` into a map of `len` keys
  would walk more than the budget: `Ord` compares it with up to
  ⌈log2(len + 1)⌉ + 1 keys (Rust's `charge_insertion`).
  """
  @spec charge_insertion(value, non_neg_integer()) :: :ok
  def charge_insertion(key, _len) when is_number(key) or is_atom(key), do: :ok

  def charge_insertion(key, len) do
    comparisons = ceil_log2(len + 1) + 1
    if weight(key, @budget + 1) * comparisons > @budget, do: out_of_steps!(), else: :ok
  end

  defp fun_order(f) do
    case fun_key(f) do
      {:closure, m, i, u} -> {0, m, i, u}
      {:def, m, n, a} -> {1, m, n, a}
      {:ctor, o, v, a} -> {2, o, v, a}
    end
  end

  # `{weight up to cap, whether a function was met}` (see `weight/2`).
  defp scan(v, cap), do: scan([v], 0, cap, false)

  defp scan(_, total, cap, fun?) when total >= cap, do: {cap, fun?}
  defp scan([], total, _, fun?), do: {total, fun?}
  defp scan([f | rest], total, cap, _) when is_function(f), do: scan(rest, total + 1, cap, true)
  defp scan(stack, total, cap, fun?), do: scan_step(stack, total, cap, fun?)

  defp scan_step([v | rest], total, cap, fun?) do
    {pushed, cost} = expand(v)
    scan(pushed ++ rest, total + cost, cap, fun?)
  end

  defp ceil_log2(n), do: ceil_log2(n, 0)
  defp ceil_log2(n, k) when Bitwise.bsl(1, k) >= n, do: k
  defp ceil_log2(n, k), do: ceil_log2(n, k + 1)

  @doc """
  A map literal's pairs, a later key replacing an earlier one, each key
  charged as an insertion (`charge_insertion/2`) before it is hashed.
  """
  @spec map_from_list([{value, value}]) :: map()
  def map_from_list(pairs) do
    Enum.reduce(pairs, %{}, fn {k, v}, acc ->
      charge_insertion(k, map_size(acc))
      Map.put(acc, k, v)
    end)
  end

  @doc """
  `v`'s weight (Rust's `weight`), up to `cap`: a node per value, a string
  one more per #{@bytes_per_step} bytes. Walked with an explicit stack in
  ordinary code, so it yields, and stops at `cap`.
  """
  @spec weight(value, non_neg_integer()) :: non_neg_integer()
  def weight(v, cap), do: v |> scan(cap) |> elem(0)

  # What walking `v` (or a walk marker) costs, and what it leaves to walk.
  # Markers are tagged with atoms no Yabu value holds.
  defp expand(v) do
    case v do
      s when is_binary(s) -> {[], 1 + Kernel.div(byte_size(s), @bytes_per_step)}
      l when is_list(l) -> {[{:"$items", l}], 1}
      {:"$items", []} -> {[], 0}
      {:"$items", [x | xs]} -> {[x, {:"$items", xs}], 0}
      m when is_map(m) -> {[{:"$entries", :maps.next(:maps.iterator(m))}], 1}
      {:"$entries", :none} -> {[], 0}
      {:"$entries", {k, x, it}} -> {[k, x, {:"$entries", :maps.next(it)}], 0}
      {:rec, _, fields} -> {[{:"$values", :maps.next(:maps.iterator(fields))}], 1}
      {:"$values", :none} -> {[], 0}
      {:"$values", {_, x, it}} -> {[x, {:"$values", :maps.next(it)}], 0}
      {:var, _, _, args} -> {[{:"$items", args}], 1}
      {:cmd, c} -> {[{:"$cmd", c}], 1}
      {:"$cmd", {:batch, cs}} -> {Enum.map(cs, &{:"$cmd", &1}), 0}
      {:"$cmd", {:effect, _, _, args}} -> {[{:"$items", args}], 0}
      {:"$cmd", _} -> {[], 0}
      {:uuid, _} -> {[], 1}
      t when is_tuple(t) -> {Tuple.to_list(t), 1}
      _ -> {[], 1}
    end
  end

  defp kind(v) when is_integer(v), do: 0
  defp kind(v) when is_binary(v), do: 1
  defp kind(v) when is_boolean(v), do: 2
  defp kind({:uuid, _}), do: 3
  defp kind(v) when is_list(v), do: 4
  defp kind(v) when is_map(v), do: 5
  defp kind({:rec, _, _}), do: 7
  defp kind({:var, _, _, _}), do: 8
  defp kind({:cmd, _}), do: 10
  defp kind(v) when is_tuple(v), do: 6
  defp kind(v) when is_function(v), do: 9

  defp same_kind(k, a, b) when k in [0, 1, 2], do: order(a, b)
  defp same_kind(3, {:uuid, a}, {:uuid, b}), do: order(a, b)
  defp same_kind(4, a, b), do: lexicographic(a, b, &cmp/2)
  defp same_kind(5, a, b), do: lexicographic(sorted(a), sorted(b), &entry/2)
  defp same_kind(6, a, b), do: lexicographic(Tuple.to_list(a), Tuple.to_list(b), &cmp/2)

  defp same_kind(7, {:rec, m, f}, {:rec, n, g}) do
    # field names are unique, so sorting the pairs sorts them by name
    ord_then(order(m, n), fn ->
      lexicographic(Enum.sort(Map.to_list(f)), Enum.sort(Map.to_list(g)), &entry/2)
    end)
  end

  defp same_kind(8, {:var, o, v, xs}, {:var, p, w, ys}) do
    ord_then(order(o, p), fn ->
      ord_then(order(v, w), fn -> lexicographic(xs, ys, &cmp/2) end)
    end)
  end

  # Rust orders closures before defs and constructors; here closures by
  # their code's identity, the rest by what they name. Never by environment.
  defp same_kind(9, a, b), do: order(fun_order(a), fun_order(b))
  defp same_kind(10, {:cmd, a}, {:cmd, b}), do: bare_cmd(a, b)

  # Rust's `Cmd` Ord: None < Batch < Effect, then their parts.
  defp bare_cmd(a, b) do
    case {cmd_rank(a), cmd_rank(b)} do
      {r, r} -> bare_cmd_parts(a, b)
      {r, s} when r < s -> :lt
      _ -> :gt
    end
  end

  defp cmd_rank(:none), do: 0
  defp cmd_rank({:batch, _}), do: 1
  defp cmd_rank({:effect, _, _, _}), do: 2

  defp bare_cmd_parts(:none, :none), do: :eq
  defp bare_cmd_parts({:batch, xs}, {:batch, ys}), do: lexicographic(xs, ys, &bare_cmd/2)

  defp bare_cmd_parts({:effect, n, m, xs}, {:effect, o, p, ys}) do
    ord_then(order(n, o), fn ->
      ord_then(model_order(m, p), fn -> lexicographic(xs, ys, &cmp/2) end)
    end)
  end

  # Rust's `Option`: `None` before `Some`.
  defp model_order(nil, nil), do: :eq
  defp model_order(nil, _), do: :lt
  defp model_order(_, nil), do: :gt
  defp model_order(a, b), do: order(a, b)

  defp entry({k, v}, {l, w}), do: ord_then(cmp(k, l), fn -> cmp(v, w) end)

  defp lexicographic([], [], _), do: :eq
  defp lexicographic([], _, _), do: :lt
  defp lexicographic(_, [], _), do: :gt

  defp lexicographic([x | xs], [y | ys], cmp) do
    case cmp.(x, y) do
      :eq -> lexicographic(xs, ys, cmp)
      ord -> ord
    end
  end

  defp ord_then(:eq, next), do: next.()
  defp ord_then(ord, _), do: ord

  defp order(a, b) when a < b, do: :lt
  defp order(a, b) when a > b, do: :gt
  defp order(_, _), do: :eq

  # ---------- records and variants ----------

  @doc "A record of `model`, its fields by name."
  def record(model, fields) when is_binary(model) and is_map(fields), do: {:rec, model, fields}

  @doc "A variant `owner.variant(args)`."
  def variant(owner, variant, args) when is_list(args), do: {:var, owner, variant, args}

  @doc "`record.field`."
  def field({:rec, model, fields}, field) do
    case fields do
      %{^field => v} -> v
      _ -> error!("a `#{model}` has no field `#{field}`")
    end
  end

  def field(v, _), do: mismatch!("a record", v)

  @doc "`%M{record | fields}`: the record's model, the fields set."
  def update({:rec, model, fields}, set), do: {:rec, model, Map.merge(fields, set)}
  def update(_, _), do: error!("an update of something not a record")

  @doc """
  A constructor used as a value (`M.Msg.Got`): a fun of `arity` that builds
  the variant. `arity` is 1 to 8 (a nullary variant is a value, not a fun).
  """
  def ctor(owner, variant, 1), do: fn a -> {:var, owner, variant, [a]} end
  def ctor(owner, variant, 2), do: fn a, b -> {:var, owner, variant, [a, b]} end
  def ctor(owner, variant, 3), do: fn a, b, c -> {:var, owner, variant, [a, b, c]} end
  def ctor(owner, variant, 4), do: fn a, b, c, d -> {:var, owner, variant, [a, b, c, d]} end

  def ctor(owner, variant, 5),
    do: fn a, b, c, d, e -> {:var, owner, variant, [a, b, c, d, e]} end

  def ctor(owner, variant, 6),
    do: fn a, b, c, d, e, f -> {:var, owner, variant, [a, b, c, d, e, f]} end

  def ctor(owner, variant, 7),
    do: fn a, b, c, d, e, f, g -> {:var, owner, variant, [a, b, c, d, e, f, g]} end

  def ctor(owner, variant, 8),
    do: fn a, b, c, d, e, f, g, h -> {:var, owner, variant, [a, b, c, d, e, f, g, h]} end

  # ---------- Cmd ----------

  @doc "`Cmd.none()`."
  def cmd_none, do: {:cmd, :none}

  @doc "`Cmd.batch(cmds)`: the commands as given, each held bare."
  def cmd_batch(cmds) when is_list(cmds) do
    {:cmd, {:batch, Enum.map(cmds, &bare/1)}}
  end

  defp bare({:cmd, c}), do: c
  defp bare(_), do: error!("`Cmd.batch` applied to arguments of the wrong kinds")

  @doc """
  An effect: its stdlib name (`"Cmd.store.insert"`), the model a store read
  reads (else `nil`) and its arguments in order, callbacks as the funs they
  are.
  """
  def cmd_effect(name, model, args) when is_binary(name) and is_list(args),
    do: {:cmd, {:effect, name, model, args}}

  # ---------- Html ----------

  @doc """
  `Html.Element(tag, attrs, children)`. `attrs` are `{name, value}` pairs
  (an event named `"on-…"`); each child is spliced as Rust's evaluator
  splices it: `Html` as itself, a list's items in its place, a string as
  `Html.Text`, an Int or a Bool as its text, a Uuid as its spelling.
  """
  def html_element(tag, attrs, children) when is_binary(tag) and is_list(attrs) do
    {:var, "Html", "Element", [tag, attrs, splice(children, [])]}
  end

  @doc "`Html.Text(text)`."
  def html_text(text) when is_binary(text), do: {:var, "Html", "Text", [text]}

  defp splice([], acc), do: Enum.reverse(acc)
  defp splice([child | rest], acc), do: splice(rest, child(child, acc))

  defp child({:var, "Html", _, _} = html, acc), do: [html | acc]
  defp child(items, acc) when is_list(items), do: Enum.reduce(items, acc, &child/2)
  defp child(s, acc) when is_binary(s), do: [html_text(s) | acc]
  defp child(n, acc) when is_integer(n), do: [html_text(Integer.to_string(n)) | acc]
  defp child(b, acc) when is_boolean(b), do: [html_text(Atom.to_string(b)) | acc]
  defp child({:uuid, s}, acc), do: [html_text(s) | acc]
  defp child(v, _), do: mismatch!("Html, text or a list of them", v)

  @doc "A `case` no arm matched (the checker makes this unreachable)."
  def no_arm!, do: error!("no case arm matched")

  # ---------- kinds ----------

  @doc "A value of the wrong kind: Rust's `mismatch`, naming the kind."
  @spec mismatch!(String.t(), value) :: no_return()
  def mismatch!(what, v), do: error!("expected #{what}, got #{kind_name(v)}")

  @doc "A value's kind, as Rust's errors name it (`\"an Int\"`, `\"a record\"`)."
  def kind_name(v) do
    elem(
      {"an Int", "a String", "a Bool", "a Uuid", "a List", "a Map", "a tuple", "a record",
       "a variant", "a function", "a Cmd"},
      kind(v)
    )
  end
end
