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
  throw Rust's `"evaluation took more than 1000000 steps"`. Rust says a closure
  equals nothing (not even itself); here funs compare by Erlang's fun
  equality. The checker keeps functions out of map keys, so the difference
  shows only for `==` on closures.

  `compare/2` is Rust's `Value` `Ord`: first by kind (Int, String, Bool,
  Uuid, List, Map, tuple, record, variant, function, Cmd), then
  structurally. Functions order by Erlang term order (Rust: closures by
  identity, then defs and constructors by name).
  """

  import Kernel, except: [div: 2]

  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807

  @type value :: term()

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

  @doc "Yabu `==`: structural, within the walk budget (`charge_comparison/2`)."
  def eq(a, b) when is_number(a) or is_atom(a) or is_number(b) or is_atom(b), do: a === b
  def eq(a, b) when is_binary(a) and is_binary(b), do: a === b

  def eq(a, b) do
    charge_comparison(a, b)
    a === b
  end

  @doc "Rust's `Value` `Ord`: `:lt`, `:eq` or `:gt`, within the walk budget."
  @spec compare(value, value) :: :lt | :eq | :gt
  def compare(a, b) do
    charge_comparison(a, b)
    cmp(a, b)
  end

  @doc "`compare(a, b) != :gt`: a sorter for `Enum.sort/2`."
  def le(a, b), do: compare(a, b) != :gt

  @doc "A map's entries in Yabu key order (`compare/2`)."
  def sorted_entries(map) when is_map(map) do
    map |> Map.to_list() |> Enum.sort(fn {a, _}, {b, _} -> le(a, b) end)
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

  @budget 1_000_000
  @bytes_per_step 64

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
  def weight(v, cap), do: walk([v], 0, cap)

  defp walk(_, total, cap) when total >= cap, do: cap
  defp walk([], total, _), do: total

  defp walk([v | rest], total, cap) do
    case v do
      s when is_binary(s) ->
        walk(rest, total + 1 + Kernel.div(byte_size(s), @bytes_per_step), cap)

      l when is_list(l) ->
        walk([{:"$items", l} | rest], total + 1, cap)

      {:"$items", []} ->
        walk(rest, total, cap)

      {:"$items", [x | xs]} ->
        walk([x, {:"$items", xs} | rest], total, cap)

      m when is_map(m) ->
        walk([{:"$entries", :maps.next(:maps.iterator(m))} | rest], total + 1, cap)

      {:"$entries", :none} ->
        walk(rest, total, cap)

      {:"$entries", {k, x, it}} ->
        walk([k, x, {:"$entries", :maps.next(it)} | rest], total, cap)

      {:rec, _, fields} ->
        walk([{:"$values", :maps.next(:maps.iterator(fields))} | rest], total + 1, cap)

      {:"$values", :none} ->
        walk(rest, total, cap)

      {:"$values", {_, x, it}} ->
        walk([x, {:"$values", :maps.next(it)} | rest], total, cap)

      {:var, _, _, args} ->
        walk([{:"$items", args} | rest], total + 1, cap)

      {:cmd, c} ->
        walk([{:"$cmd", c} | rest], total + 1, cap)

      {:"$cmd", {:batch, cs}} ->
        walk(Enum.map(cs, &{:"$cmd", &1}) ++ rest, total, cap)

      {:"$cmd", {:effect, _, _, args}} ->
        walk([{:"$items", args} | rest], total, cap)

      {:"$cmd", _} ->
        walk(rest, total, cap)

      {:uuid, _} ->
        walk(rest, total + 1, cap)

      t when is_tuple(t) ->
        walk(Tuple.to_list(t) ++ rest, total + 1, cap)

      _ ->
        walk(rest, total + 1, cap)
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

  defp same_kind(9, a, b), do: order(a, b)
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

  # ---------- assertions ----------

  @doc "`always(held)`: Unit when it holds, else a runtime error."
  def always!(true), do: {}
  def always!(false), do: error!("always failed")

  @doc "`always(held)` at the site whose source is `source`."
  def always!(true, _source), do: {}
  def always!(false, source), do: error!("always failed: #{source}")

  @doc "`sometimes(held)`: evaluated for its effect on nothing; Unit."
  def sometimes(_held), do: {}

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
