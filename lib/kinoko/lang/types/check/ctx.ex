defmodule Kinoko.Lang.Types.Check.Ctx do
  @moduledoc """
  One check's state (Rust's `Ctx`, TS's `Ctx`), built fresh for every check
  so one check's errors never leak into another's, and the primitives every
  part of the checker shares: signature lookup (`dget/2`, the only way a
  signature is read, so `used` is exactly what the check consulted), local
  scopes, and thin wrappers over `Infer` that thread the state.

  `sigs` is a map `%{name => signature}` or a lookup function
  `(name -> signature | nil)`; both are read only through `dget/2`, which
  also records the name in `looked_up` (`record/2`, for a group's names,
  touches `used` alone).

  `scopes` is innermost first and never empty. `pending` and `tuple_cases`
  are kept newest first; their takers reverse them.

  The map-key rule's memo (`keys`, `key_recorded`, `reported_non_data_maps`)
  belongs to `Kinoko.Lang.Types.Keys`; the unbound-name caches (`names`,
  `sorted`, `table_says`) to `Kinoko.Lang.Types.Hints`. Both only ever speed a check
  up: what a check gives does not depend on them.
  """

  alias Kinoko.Lang.Types.Infer

  defstruct infer: nil,
            sigs: %{},
            scopes: [%{}],
            used: MapSet.new(),
            looked_up: MapSet.new(),
            pending: [],
            tuple_cases: [],
            open_names: %{},
            keys: nil,
            key_recorded: MapSet.new(),
            reported_non_data_maps: MapSet.new(),
            names: nil,
            sorted: nil,
            table_says: %{}

  @type t :: %__MODULE__{}

  @spec new(map() | (String.t() -> term())) :: t()
  def new(sigs),
    do: %__MODULE__{infer: Infer.new(), sigs: sigs, keys: Kinoko.Lang.Types.Keys.new()}

  @doc """
  The signature `name` has (TS's `dget`), recording `name` as consulted
  whether or not it is there: declaring it later must check this again.
  """
  def dget(%__MODULE__{} = ctx, name) do
    sig =
      case ctx.sigs do
        sigs when is_map(sigs) -> Map.get(sigs, name)
        lookup when is_function(lookup, 1) -> lookup.(name)
      end

    {sig, %{ctx | used: MapSet.put(ctx.used, name), looked_up: MapSet.put(ctx.looked_up, name)}}
  end

  @doc "`names` recorded as consulted, without a lookup (they were read already)."
  def record(%__MODULE__{} = ctx, names), do: %{ctx | used: MapSet.union(ctx.used, names)}

  # --- scopes -------------------------------------------------------------

  def lookup_local(ctx, name), do: Enum.find_value(ctx.scopes, &Map.get(&1, name))

  def push_scope(ctx, scope \\ %{}), do: %{ctx | scopes: [scope | ctx.scopes]}
  def pop_scope(%{scopes: [_ | rest]} = ctx), do: %{ctx | scopes: rest}

  def bound_here?(%{scopes: [scope | _]}, name), do: Map.has_key?(scope, name)

  @doc """
  Binds `name` in the innermost scope, checked as an identifier (codegen
  refuses `__proto__` and friends), its type measured as every type the
  check goes on with.
  """
  def bind_local(ctx, name, ty) do
    ctx = check_ident(ctx, name)
    {_, ctx} = fits_quoting(ctx, ty, fn -> Kinoko.Lang.Types.Quote.cut(name) end)
    [scope | rest] = ctx.scopes
    %{ctx | scopes: [Map.put(scope, name, ty) | rest]}
  end

  # --- names --------------------------------------------------------------

  @dangerous ~w(__proto__ constructor prototype)

  @doc "`name` is a plain identifier and not one codegen refuses."
  def check_ident(ctx, name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name) and name not in @dangerous,
      do: ctx,
      else: error(ctx, "bad-name", "`#{name}` is not a valid identifier")
  end

  @doc "Each of `names` once: every repeat is a `bad-name`, worded by `again`."
  def refuse_repeated(ctx, names, again) do
    {ctx, _} =
      Enum.reduce(names, {ctx, MapSet.new()}, fn name, {ctx, seen} ->
        if MapSet.member?(seen, name),
          do: {error(ctx, "bad-name", again.(name)), seen},
          else: {ctx, MapSet.put(seen, name)}
      end)

    ctx
  end

  # --- inference, threaded ------------------------------------------------

  def error(ctx, code, message), do: %{ctx | infer: Infer.error(ctx.infer, code, message)}

  def fresh(ctx) do
    {u, infer} = Infer.fresh(ctx.infer)
    {u, %{ctx | infer: infer}}
  end

  def fresh_n(ctx, n),
    do: Enum.map_reduce(List.duplicate(nil, n), ctx, fn _, ctx -> fresh(ctx) end)

  def alias_type(ctx, t) do
    {u, infer} = Infer.alias(ctx.infer, t)
    {u, %{ctx | infer: infer}}
  end

  def written(ctx, t) do
    {t, infer} = Infer.written(ctx.infer, t)
    {t, %{ctx | infer: infer}}
  end

  def stopped?(ctx), do: Infer.stopped?(ctx.infer)
  def no_errors?(ctx), do: Infer.error_count(ctx.infer) == 0
  def errors(ctx), do: Infer.errors(ctx.infer)
  def shallow(ctx, t), do: Infer.shallow(ctx.infer, t)
  def format(ctx, t), do: Infer.format_itype(ctx.infer, t)

  @doc "Unifies `a` with `b` (`b` is what was expected); whether it held."
  def unify(ctx, a, b, context) do
    case Infer.unify(ctx.infer, a, b, context) do
      {:ok, infer} -> {true, %{ctx | infer: infer}}
      {:error, _code, infer} -> {false, %{ctx | infer: infer}}
    end
  end

  @doc "`unify/4`, the boolean dropped."
  def unify!(ctx, a, b, context) do
    {_, ctx} = unify(ctx, a, b, context)
    ctx
  end

  def unify_quoting(ctx, a, b, quote) do
    case Infer.unify_quoting(ctx.infer, a, b, quote) do
      {:ok, infer} -> {true, %{ctx | infer: infer}}
      {:error, _code, infer} -> {false, %{ctx | infer: infer}}
    end
  end

  def fits(ctx, t, expr) do
    {ok, infer} = Infer.fits(ctx.infer, t, expr)
    {ok, %{ctx | infer: infer}}
  end

  def fits_quoting(ctx, t, quote) do
    {ok, infer} = Infer.fits_quoting(ctx.infer, t, quote)
    {ok, %{ctx | infer: infer}}
  end

  def resolve_deep(ctx, t, quote) do
    {t, infer} = Infer.resolve_deep(ctx.infer, t, quote)
    {t, %{ctx | infer: infer}}
  end

  @doc """
  `t` instantiated: `params` (a deftype's, by membership) and scheme
  variables freshened, sharing `mapping`. Returns `{type, mapping, ctx}`.
  """
  def instantiate(ctx, t, params, mapping) do
    {t, mapping, infer} = Infer.instantiate(ctx.infer, t, params, mapping)
    {t, mapping, %{ctx | infer: infer}}
  end
end
