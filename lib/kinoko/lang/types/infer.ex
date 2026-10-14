defmodule Kinoko.Lang.Types.Infer do
  @moduledoc """
  Unification engine (ported from `types/infer.rs`): inference variables, the
  substitution, the occurs check, scheme instantiation, and the size limits
  that keep a doubling type (`(x, x)` repeated) from exhausting memory.

  Pure: every operation takes the state and returns the new one. A fresh
  state is built per declaration; carrying one across declarations would leak
  one declaration's errors into another's.

  A type is the `Kinoko.Lang.Ast` type shape plus `{:uvar, n}` at any depth.
  A `{:var, name}` is a *scheme* variable (only a signature writes one) and is
  replaced by `instantiate`; one reaching `unify` is an `"internal"` error.

  Rust to Elixir names: `resolve` -> `resolve/2` (top only), `resolve_deep` ->
  `resolve_deep/3`, `quote_type` -> `Quote.type/1`, `quote_context` ->
  `Quote.expr/1`, `quote_pattern` -> `Quote.pattern/1`, `lift` -> identity,
  `errors` field -> `errors/1`. `resolve_full/2` has no Rust twin (unmeasured).
  """

  alias Kinoko.Lang.Types.Quote

  @max_type_nodes 10_000
  @base_type_work 100 * @max_type_nodes
  @type_work_per_node 64

  defstruct next: 0,
            subst: %{},
            errors: [],
            error_count: 0,
            work: 0,
            allowance: @base_type_work,
            stopped: false,
            lone_expression: false

  @type itype :: term()
  @type t :: %__MODULE__{}
  @type error :: %{code: String.t(), message: String.t()}

  def max_type_nodes, do: @max_type_nodes
  def base_type_work, do: @base_type_work
  def type_work_per_node, do: @type_work_per_node

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec fresh(t()) :: {{:uvar, non_neg_integer()}, t()}
  def fresh(%__MODULE__{next: n} = st), do: {{:uvar, n}, %{st | next: n + 1}}

  @doc "A fresh uvar bound to `t` (or `t` itself when it is already a uvar)."
  def alias(st, {:uvar, _} = t), do: {t, st}

  def alias(st, t) do
    {{:uvar, id} = u, st} = fresh(st)
    {u, %{st | subst: Map.put(st.subst, id, t)}}
  end

  @doc """
  A type the program writes. A bare `Html` is `Html<?>` with a fresh sends
  type, so the one error refusing it is all it causes.
  """
  def written(st, {:named, "Html"}) do
    {u, st} = fresh(st)
    {{:applied, "Html", [u]}, st}
  end

  def written(st, {:applied, n, args}) do
    {args, st} = Enum.map_reduce(args, st, &written(&2, &1))
    {{:applied, n, args}, st}
  end

  def written(st, {:arrow, ps, ret}) do
    {ps, st} = Enum.map_reduce(ps, st, &written(&2, &1))
    {ret, st} = written(st, ret)
    {{:arrow, ps, ret}, st}
  end

  def written(st, {:tuple, items}) do
    {items, st} = Enum.map_reduce(items, st, &written(&2, &1))
    {{:tuple, items}, st}
  end

  def written(st, t), do: {t, st}

  # --- errors -------------------------------------------------------------

  @doc "Records an error, unless the check has stopped."
  @spec error(t(), String.t(), String.t()) :: t()
  def error(%__MODULE__{stopped: true} = st, _code, _message), do: st

  def error(st, code, message),
    do: %{
      st
      | errors: [%{code: code, message: message} | st.errors],
        error_count: st.error_count + 1
    }

  @doc "The errors recorded so far, in the order they were recorded. Never read the `errors` field directly (it is reversed)."
  @spec errors(t()) :: [error()]
  def errors(st), do: Enum.reverse(st.errors)

  @doc "Records the error that ends the check: nothing after it is checked or reported."
  def stop(st, code, message), do: %{error(st, code, message) | stopped: true}

  def stopped?(st), do: st.stopped

  @doc "Lets the check measure or build `work` more type nodes."
  def allow(st, work), do: %{st | allowance: st.allowance + work}

  @doc "Marks this as the check of a lone expression, which may stay polymorphic."
  def lone_expression(st, flag \\ true), do: %{st | lone_expression: flag}

  # --- substitution -------------------------------------------------------

  @doc "What `t` is at its top: follows the uvar chain to its end."
  def shallow(%__MODULE__{subst: subst} = st, {:uvar, id} = t) do
    case subst do
      %{^id => bound} -> shallow(st, bound)
      _ -> t
    end
  end

  def shallow(_st, t), do: t

  @doc "Rust's `resolve`: what `t` is at its top only (children are left as they are)."
  @spec resolve(t(), itype()) :: itype()
  def resolve(st, t), do: shallow(st, t)

  @doc """
  `t` fully resolved: every bound uvar replaced, to a fixpoint. Unmeasured:
  never call on untrusted types; use `resolve_deep/3`, which measures first.
  """
  @spec resolve_full(t(), itype()) :: itype()
  def resolve_full(st, t) do
    case shallow(st, t) do
      {:applied, n, args} -> {:applied, n, Enum.map(args, &resolve_full(st, &1))}
      {:arrow, ps, ret} -> {:arrow, Enum.map(ps, &resolve_full(st, &1)), resolve_full(st, ret)}
      {:tuple, items} -> {:tuple, Enum.map(items, &resolve_full(st, &1))}
      other -> other
    end
  end

  @doc """
  `resolve_full`, once `t` fits (quoting `quote` if it does not). After the check
  has stopped nothing is known: a fresh uvar.
  """
  def resolve_deep(st, t, quote \\ fn -> "" end) do
    case fits_quoting(st, t, quote) do
      {true, st} -> {resolve_full(st, t), st}
      {false, st} -> fresh(st)
    end
  end

  @doc "Every uvar left in `t`, in the order it is written, without repeats."
  def uvar_ids(t), do: t |> uvar_ids_acc([]) |> Enum.reverse() |> Enum.uniq()

  defp uvar_ids_acc({:uvar, id}, acc), do: [id | acc]
  defp uvar_ids_acc({:applied, _, args}, acc), do: Enum.reduce(args, acc, &uvar_ids_acc/2)

  defp uvar_ids_acc({:arrow, ps, ret}, acc),
    do: uvar_ids_acc(ret, Enum.reduce(ps, acc, &uvar_ids_acc/2))

  defp uvar_ids_acc({:tuple, items}, acc), do: Enum.reduce(items, acc, &uvar_ids_acc/2)
  defp uvar_ids_acc(_, acc), do: acc

  def contains_uvar?(t), do: uvar_ids(t) != []

  @doc "Replaces every uvar by `{:var, namer.(id)}`, at any depth."
  def strip_uvars({:uvar, id}, namer), do: {:var, namer.(id)}

  def strip_uvars({:applied, n, args}, namer),
    do: {:applied, n, Enum.map(args, &strip_uvars(&1, namer))}

  def strip_uvars({:arrow, ps, ret}, namer),
    do: {:arrow, Enum.map(ps, &strip_uvars(&1, namer)), strip_uvars(ret, namer)}

  def strip_uvars({:tuple, items}, namer), do: {:tuple, Enum.map(items, &strip_uvars(&1, namer))}
  def strip_uvars(t, _namer), do: t

  # --- size limits --------------------------------------------------------

  @doc """
  The nodes of `t` fully resolved, counted no further than `limit` (`nil`
  past it). Nothing is built.
  """
  def size_within(st, t, limit) do
    case shallow(st, t) do
      s when elem(s, 0) in [:uvar, :named, :var] -> if limit > 0, do: 1
      _ -> count_nodes(st, [t], 1, 0, limit)
    end
  end

  # `todo` is the stack of nodes still to count and `len` its length (each
  # node waiting is one more).
  defp count_nodes(_st, [], _len, count, _limit), do: count

  defp count_nodes(st, [t | todo], len, count, limit) do
    pushed =
      case shallow(st, t) do
        {:applied, _, args} -> args
        {:arrow, ps, ret} -> ps ++ [ret]
        {:tuple, items} -> items
        _ -> []
      end

    count = count + 1
    len = len - 1 + length(pushed)

    if count + len > limit,
      do: nil,
      else: count_nodes(st, pushed ++ todo, len, count, limit)
  end

  @doc "`fits_quoting` for a type of an expression being checked."
  def fits(st, t, context), do: fits_quoting(st, t, fn -> Quote.expr(context) end)

  @doc """
  Whether `t` is small enough to go on with (`max_type_nodes`), and the
  declaration's types with it (its allowance). When not, the check stops,
  quoting what `quote` says.
  """
  @spec fits_quoting(t(), itype(), (-> String.t())) :: {boolean(), t()}
  def fits_quoting(%__MODULE__{stopped: true} = st, _t, _quote), do: {false, st}

  def fits_quoting(st, t, quote) do
    case size_within(st, t, @max_type_nodes) do
      nil ->
        message = "the type of `#{quote.()}` is too large: more than #{@max_type_nodes} nodes"
        {false, stop(st, "type-too-large", message)}

      nodes ->
        st = %{st | work: st.work + nodes}

        if st.work > st.allowance do
          message =
            "the types of this declaration are too large for its size: at `#{quote.()}`, " <>
              "checking it has walked more than #{st.allowance} type nodes"

          {false, stop(st, "type-too-large", message)}
        else
          {true, st}
        end
    end
  end

  @doc "Whether `t` is within the size limits: `{:ok, st}` or `{:error, \"type-too-large\", st}`."
  def check_size(st, t, quote \\ fn -> "" end) do
    case fits_quoting(st, t, quote) do
      {true, st} -> {:ok, st}
      {false, st} -> {:error, "type-too-large", st}
    end
  end

  # --- formatting ---------------------------------------------------------

  @doc """
  `t`, resolved, formatted for a message and cut at the quote limit then `…`,
  written no further than the cut. A residual uvar prints `?id`, or `_` in a
  lone expression's check.
  """
  def format_itype(st, t) do
    limit = Quote.limit()
    {parts, n} = write(st, t, {[], 0}, limit)
    text = parts |> Enum.reverse() |> IO.iodata_to_binary()
    if n > limit, do: Quote.take(text, limit) <> "…", else: text
  end

  # The accumulator is {reversed pieces, chars written}; writing stops once
  # past `limit` characters (which tells `format_itype` to cut).
  defp write(_st, _t, {_, n} = acc, limit) when n > limit, do: acc

  defp write(st, t, acc, limit) do
    case shallow(st, t) do
      {:uvar, id} ->
        push(acc, if(st.lone_expression, do: "_", else: "?#{id}"))

      {:named, name} ->
        push(acc, name)

      {:var, name} ->
        push(acc, name)

      {:applied, name, args} ->
        acc |> push(name) |> push("<") |> write_all(st, args, limit) |> push(">")

      {:arrow, ps, ret} ->
        write_arrow(st, ps, ret, acc, limit)

      {:tuple, items} ->
        acc |> push("(") |> write_all(st, items, limit) |> push(")")
    end
  end

  defp write_arrow(st, ps, ret, acc, limit) do
    acc = push(acc, "(")
    acc = if ps == [], do: push(acc, "()"), else: write_all(acc, st, ps, limit)
    acc = push(acc, " -> ")
    acc = write(st, ret, acc, limit)
    push(acc, ")")
  end

  defp write_all({_, n} = acc, _st, _ts, limit) when n > limit, do: acc

  defp write_all(acc, st, ts, limit) do
    ts
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {t, i}, {_, n} = acc ->
      if n > limit do
        acc
      else
        acc = if i > 0, do: push(acc, ", "), else: acc
        write(st, t, acc, limit)
      end
    end)
  end

  defp push({parts, n}, s), do: {[s | parts], n + Quote.length(s)}

  # --- unification --------------------------------------------------------

  @doc """
  Unifies `a` and `b`. On failure records exactly one error (`"mismatch"`,
  `"occurs"`, `"internal"`, or `"type-too-large"`) and returns its code with
  the state. `context` is an expression, a `fn -> String` quoter, or `nil`.
  """
  @spec unify(t(), itype(), itype(), term()) :: {:ok, t()} | {:error, String.t(), t()}
  def unify(st, a, b, context \\ nil), do: unify_quoting(st, a, b, quoter(context))

  defp quoter(nil), do: fn -> "" end
  defp quoter(f) when is_function(f, 0), do: f
  defp quoter(expr), do: fn -> Quote.expr(expr) end

  def unify_quoting(st, a, b, quote) do
    before = st.error_count

    with {true, st} <- fits_quoting(st, a, quote),
         {true, st} <- fits_quoting(st, b, quote) do
      case unify_inner(st, a, b, quote) do
        {:ok, st} ->
          {:ok, st}

        {:error, :mismatch, st} ->
          {:error, "mismatch", record_mismatch(st, a, b, quote)}

        {:error, code, st} ->
          {:error, code, record_mismatch(st, a, b, quote)}
      end
    else
      {false, st} -> {:error, failure_code(st, before), st}
    end
  end

  # Like Rust, every failed comparison ends with a mismatch (a no-op once
  # the check has stopped), even after "occurs".
  defp record_mismatch(st, a, b, quote) do
    if st.stopped do
      st
    else
      got = format_itype(st, a)
      expected = format_itype(st, b)
      error(st, "mismatch", "type mismatch: expected #{expected}, got #{got} in `#{quote.()}`")
    end
  end

  # The code of the first error this unification recorded (a size stop).
  defp failure_code(st, before) do
    if st.error_count > before,
      do: st.errors |> Enum.take(st.error_count - before) |> List.last() |> Map.fetch!(:code),
      else: "type-too-large"
  end

  defp unify_inner(st, a, b, quote) do
    ra = shallow(st, a)
    rb = shallow(st, b)

    case {ra, rb} do
      {{:uvar, i}, {:uvar, i}} -> {:ok, st}
      {{:uvar, id}, _} -> bind(st, id, rb, quote)
      {_, {:uvar, id}} -> bind(st, id, ra, quote)
      {{:var, name}, _} -> internal(st, name, quote)
      {_, {:var, name}} -> internal(st, name, quote)
      {{:named, n}, {:named, n}} -> {:ok, st}
      {{:applied, n, xs}, {:applied, n, ys}} -> unify_all(st, xs, ys, quote)
      {{:arrow, xs, xr}, {:arrow, ys, yr}} -> unify_arrow(st, xs, xr, ys, yr, quote)
      {{:tuple, xs}, {:tuple, ys}} -> unify_all(st, xs, ys, quote)
      _ -> {:error, :mismatch, st}
    end
  end

  defp internal(st, name, quote) do
    message = "the checker met the type variable `#{name}` uninstantiated, in `#{quote.()}`"
    {:error, "internal", stop(st, "internal", message)}
  end

  defp unify_arrow(st, xs, xr, ys, yr, quote) do
    case unify_all(st, xs, ys, quote) do
      {:ok, st} -> unify_inner(st, xr, yr, quote)
      err -> err
    end
  end

  defp unify_all(st, xs, ys, _quote) when length(xs) != length(ys), do: {:error, :mismatch, st}

  defp unify_all(st, xs, ys, quote) do
    xs
    |> Enum.zip(ys)
    |> Enum.reduce_while({:ok, st}, fn {x, y}, {:ok, st} ->
      case unify_inner(st, x, y, quote) do
        {:ok, _} = ok -> {:cont, ok}
        err -> {:halt, err}
      end
    end)
  end

  defp bind(st, id, t, quote) do
    if occurs?(st, id, t) do
      message = "recursive type: cannot construct the infinite type in `#{quote.()}`"
      {:error, "occurs", error(st, "occurs", message)}
    else
      {:ok, %{st | subst: Map.put(st.subst, id, t)}}
    end
  end

  defp occurs?(st, id, t) do
    case shallow(st, t) do
      {:uvar, rid} -> rid == id
      {:applied, _, args} -> Enum.any?(args, &occurs?(st, id, &1))
      {:arrow, ps, ret} -> Enum.any?(ps, &occurs?(st, id, &1)) or occurs?(st, id, ret)
      {:tuple, items} -> Enum.any?(items, &occurs?(st, id, &1))
      _ -> false
    end
  end

  # --- instantiation ------------------------------------------------------

  @doc "Replaces every `{:var, _}` of a scheme type with a fresh uvar, one per distinct name."
  @spec instantiate(t(), term()) :: {itype(), t()}
  def instantiate(st, t) do
    {t, _mapping, st} = instantiate(st, t, MapSet.new(), %{})
    {t, st}
  end

  @doc """
  `instantiate/2` with a deftype's declared `params` (written as ordinary
  `{:named, p}` and recognised only by membership) and a shared `mapping`
  (name => uvar) so several types of one signature share their variables.
  Every node built counts as work. Returns `{type, mapping, st}`.
  """
  def instantiate(st, t, params, mapping) do
    st = %{st | work: st.work + 1}

    case t do
      {:var, name} ->
        mapped(st, name, mapping)

      {:named, name} ->
        if MapSet.member?(params, name),
          do: mapped(st, name, mapping),
          else: {t, mapping, st}

      {:applied, n, args} ->
        {args, mapping, st} = instantiate_all(st, args, params, mapping)
        {{:applied, n, args}, mapping, st}

      {:arrow, ps, ret} ->
        {ps, mapping, st} = instantiate_all(st, ps, params, mapping)
        {ret, mapping, st} = instantiate(st, ret, params, mapping)
        {{:arrow, ps, ret}, mapping, st}

      {:tuple, items} ->
        {items, mapping, st} = instantiate_all(st, items, params, mapping)
        {{:tuple, items}, mapping, st}
    end
  end

  defp instantiate_all(st, ts, params, mapping) do
    {ts, {mapping, st}} =
      Enum.map_reduce(ts, {mapping, st}, fn t, {mapping, st} ->
        {t, mapping, st} = instantiate(st, t, params, mapping)
        {t, {mapping, st}}
      end)

    {ts, mapping, st}
  end

  defp mapped(st, name, mapping) do
    case mapping do
      %{^name => u} ->
        {u, mapping, st}

      _ ->
        {u, st} = fresh(st)
        {u, Map.put(mapping, name, u), st}
    end
  end
end
