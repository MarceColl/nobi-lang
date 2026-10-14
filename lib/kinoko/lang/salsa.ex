defmodule Kinoko.Lang.Salsa do
  @moduledoc """
  A salsa: queries memoized over inputs in layers, computed again only when
  something they read changed. A pure port of `crates/yabu/src/salsa.rs`;
  the database is a value threaded through every call.

  - Inputs live in layers. A context is an ordered list of layers: a read
    takes the first layer that holds the key, and a tombstone held there
    reads as nothing (`nil`).
  - A query is a pure function of what it reads, inputs and queries alike.
    Its memo records every read and what it gave, in order.
  - Asked in a context, a query reuses a memo whose every read still gives
    what it gave there (red-green). The walk stops at the first read that
    differs, so it asks only what computing again would ask.
  - Reads compare by value (`===`). A query computed again to an equal value
    changes nothing that read it (early cutoff), and a memo serves every
    context where its reads agree: one that reads no layered input is
    computed once for all of them.
  - The revision moves only when an input changes. A memo verified in a
    context at the current revision is reused without the walk.
  - A query keeps every memo used at the current revision, since a search's
    trials may come back to any of them, and the `versions` (default 4) most
    recently used before it. `trim/1` drops a version that read what no memo
    gives any more.
  - A query asking for itself is `{:error, {:cycle, query}}`; queries nested
    past `depth` (default 256) are `{:error, :too_deep}`. Either fails every
    query that met it, even one whose body ignored it: its value would
    depend on who asked, not only on what it read.

  ## Values and errors

  The compute callback returns `{{:ok, out} | {:error, term}, reads}`. When
  no read failed, that whole result is the query's value: it is memoized,
  compared for early cutoff, and returned as is by `query/3` and `ask/2`. So
  a domain error (`{:error, {:unbound, "x"}}`) is memoized like any value,
  and the salsa's own errors (`{:error, {:cycle, q}}`, `{:error, :too_deep}`)
  are never memoized. A caller tells them apart by their shape.

  ## Stats

  `stats/1` reports `computes: %{query => n}`: how many times each query's
  body ran over the database's whole life, failed runs included. It is
  cumulative: `retain/2`, `retain_reads/2` and `trim/1` drop memos, never
  counts.
  """

  alias Kinoko.Lang.Salsa.Reads

  @callback compute(query :: term(), Reads.t()) ::
              {{:ok, term()} | {:error, term()}, Reads.t()}

  @versions 4
  @depth 256

  defstruct [
    :mod,
    :env,
    versions: @versions,
    depth: @depth,
    revision: 0,
    layers: %{},
    memos: %{},
    verified: %{},
    computes: %{}
  ]

  @typedoc "A query's value, as its compute gave it."
  @type result :: {:ok, term()} | {:error, term()}
  @type error :: {:error, {:cycle, term()} | :too_deep}
  @type t :: %__MODULE__{}

  # Internals:
  # - layers:   %{layer => %{key => value | :tombstone}}
  # - memos:    %{query => [{memo, used_at_revision}]}, most recently used first;
  #             memo = %{value: result, reads: [{:input, key, value | nil} | {:query, q, result}]}
  # - verified: %{ctx => %{query => {memo, height}}}, at the current revision only.
  #             A memo's height is how deep the queries it reads nest, itself
  #             included: a memo never answers what computing it would refuse.

  @doc """
  A database computing with `mod`. Options: `versions:` (memos kept per
  query beside those used at the current revision, default 4), `depth:`
  (nesting limit, default 256), `env:` (any term the callback reads with
  `env/1`, as Rust's `&self`).
  """
  @spec new(module(), keyword()) :: t()
  def new(mod, opts \\ []) do
    %__MODULE__{
      mod: mod,
      env: Keyword.get(opts, :env),
      versions: Keyword.get(opts, :versions, @versions),
      depth: Keyword.get(opts, :depth, @depth)
    }
  end

  @doc "Moves only when an input changes."
  @spec revision(t()) :: non_neg_integer()
  def revision(%__MODULE__{revision: revision}), do: revision

  @doc """
  Make `layer` hold `value` for `key`. `:tombstone` makes the key read as
  nothing, whatever the layers below hold. Setting a value equal to the one
  held changes nothing.
  """
  @spec set(t(), term(), term(), term()) :: t()
  def set(%__MODULE__{} = db, layer, key, value) do
    held = Map.get(db.layers, layer, %{})

    case held do
      %{^key => old} when old === value -> db
      _ -> changed(%{db | layers: Map.put(db.layers, layer, Map.put(held, key, value))})
    end
  end

  @doc "Make `layer` hold nothing for `key`, so the layers below show through."
  @spec unset(t(), term(), term()) :: t()
  def unset(%__MODULE__{} = db, layer, key) do
    case db.layers do
      %{^layer => %{^key => _} = held} ->
        held = Map.delete(held, key)

        layers =
          if map_size(held) == 0,
            do: Map.delete(db.layers, layer),
            else: Map.put(db.layers, layer, held)

        changed(%{db | layers: layers})

      _ ->
        db
    end
  end

  @doc "What `query` gives in `ctx`, its first layer first."
  @spec query(t(), [term()], term()) :: {result() | error(), t()}
  def query(%__MODULE__{} = db, ctx, query) when is_list(ctx) do
    case ensure(%Reads{db: db, ctx: ctx}, query) do
      {{:ok, {memo, _}}, r} -> {memo.value, r.db}
      {{:error, e}, r} -> {{:error, e}, r.db}
    end
  end

  @doc "Inside a compute: what `key` reads as in this context, recorded."
  @spec input(Reads.t(), term()) :: {term() | nil, Reads.t()}
  def input(%Reads{} = r, key) do
    value = read_input(r.db, r.ctx, key)
    {value, %{r | reads: [{:input, key, value} | r.reads]}}
  end

  @doc """
  Inside a compute: what `key` reads as in this context, NOT recorded. For a
  body that hands a pure function (a lookup) to code that cannot thread the
  reads: the body must then record reads (`input/2`, `ask/2`) that determine
  everything it derived from what it peeked, or its memo is reused where it
  no longer holds.
  """
  @spec peek(Reads.t(), term()) :: term() | nil
  def peek(%Reads{} = r, key), do: read_input(r.db, r.ctx, key)

  @doc """
  Inside a compute: what `query` gives in this context, recorded. A salsa
  error fails the asking computation too, whatever its body makes of it.
  """
  @spec ask(Reads.t(), term()) :: {result() | error(), Reads.t()}
  def ask(%Reads{} = r, query) do
    case ensure(r, query) do
      {{:ok, {memo, height}}, r} ->
        r = %{r | height: max(r.height, height), reads: [{:query, query, memo.value} | r.reads]}
        {memo.value, r}

      {{:error, e}, r} ->
        {{:error, e}, %{r | failed: r.failed || e}}
    end
  end

  @doc "Inside a compute: the `env:` the database was made with."
  @spec env(Reads.t()) :: term()
  def env(%Reads{db: db}), do: db.env

  @doc "Drop the memos of every query `keep?` rejects; asked again, it is computed again."
  @spec retain(t(), (term() -> boolean())) :: t()
  def retain(%__MODULE__{} = db, keep?) do
    %{db | memos: Map.filter(db.memos, fn {q, _} -> keep?.(q) end), verified: %{}}
  end

  @doc """
  Drop every memo that read an input whose value `keep?` rejects (a
  tombstone or an absent key is never offered); asked again, its query is
  computed again.
  """
  @spec retain_reads(t(), (term() -> boolean())) :: t()
  def retain_reads(%__MODULE__{} = db, keep?) do
    kept? = fn {memo, _} ->
      Enum.all?(memo.reads, fn
        {:input, _, nil} -> true
        {:input, _, value} -> keep?.(value)
        {:query, _, _} -> true
      end)
    end

    %{db | memos: filter_memos(db.memos, kept?), verified: %{}}
  end

  @doc """
  Drop every memo that read a value of a query none of that query's memos
  kept gives: a version kept for a context that is gone, or one whose read
  outlived its query's versions. A query that holds no memo already is let
  be: what it gives is not known until it is asked. Dropping a memo can
  leave what read it so, so this goes on until none is.
  """
  @spec trim(t()) :: t()
  def trim(%__MODULE__{} = db) do
    held = db.memos |> Map.keys() |> MapSet.new()
    %{db | memos: trim_memos(db.memos, held), verified: %{}}
  end

  @doc "How many queries hold memos (`stats/1`'s `queries`, without walking them)."
  @spec queries(t()) :: non_neg_integer()
  def queries(%__MODULE__{memos: memos}), do: map_size(memos)

  @doc """
  `queries`: how many queries hold memos; `memos`: how many memos, all
  told; `reads`: how many reads they record; `computes`: how many times each
  query's body ran (cumulative over the database's life).
  """
  @spec stats(t()) :: %{
          queries: non_neg_integer(),
          memos: non_neg_integer(),
          reads: non_neg_integer(),
          computes: %{term() => pos_integer()}
        }
  def stats(%__MODULE__{} = db) do
    all = db.memos |> Map.values() |> Enum.concat()

    %{
      queries: map_size(db.memos),
      memos: length(all),
      reads: Enum.reduce(all, 0, fn {memo, _}, n -> n + length(memo.reads) end),
      computes: db.computes
    }
  end

  # ---------- inputs ----------

  defp changed(db), do: %{db | revision: db.revision + 1, verified: %{}}

  defp read_input(_db, [], _key), do: nil

  defp read_input(db, [layer | rest], key) do
    case db.layers do
      %{^layer => %{^key => :tombstone}} -> nil
      %{^layer => %{^key => value}} -> value
      _ -> read_input(db, rest, key)
    end
  end

  # ---------- red-green ----------

  # A memo of `query` that holds in r's context: verified already at this
  # revision, or one whose reads still give what they gave, or a new one.
  # Leaves r's own reads, height and failed untouched; only `db` moves.
  defp ensure(%Reads{db: db, ctx: ctx} = r, query) do
    case db.verified do
      %{^ctx => %{^query => {_, height} = valid}} ->
        if r.nesting + height > db.depth,
          do: {{:error, :too_deep}, r},
          else: {{:ok, valid}, r}

      _ ->
        cond do
          MapSet.member?(r.active, query) -> {{:error, {:cycle, query}}, r}
          r.nesting >= db.depth -> {{:error, :too_deep}, r}
          true -> ensure_active(r, query)
        end
    end
  end

  defp ensure_active(r, query) do
    inner = %{r | active: MapSet.put(r.active, query), nesting: r.nesting + 1}

    {result, inner} =
      case reuse(inner, query) do
        {{:ok, nil}, inner} -> compute(inner, query)
        other -> other
      end

    r = %{r | db: inner.db}

    case result do
      {:ok, valid} -> {result, %{r | db: put_verified(r.db, r.ctx, query, valid)}}
      {:error, _} -> {result, r}
    end
  end

  defp put_verified(db, ctx, query, valid) do
    verified = Map.update(db.verified, ctx, %{query => valid}, &Map.put(&1, query, valid))
    %{db | verified: verified}
  end

  # The first memo of `query` whose reads all give here what they gave,
  # marked used and moved to the front.
  defp reuse(r, query) do
    r.db.memos
    |> Map.get(query, [])
    |> Enum.with_index()
    |> Enum.reduce_while({{:ok, nil}, r}, fn {{memo, _}, i}, {_, r} ->
      case holds(r, memo) do
        {{:ok, nil}, r} ->
          {:cont, {{:ok, nil}, r}}

        {{:ok, height}, r} ->
          {:halt, {{:ok, {memo, height}}, %{r | db: mark_used(r.db, query, i)}}}

        {{:error, _}, _} = err ->
          {:halt, err}
      end
    end)
  end

  # Only `query`'s own computation touches its memos, and it is active.
  defp mark_used(db, query, i) do
    {{memo, _}, rest} = db.memos |> Map.fetch!(query) |> List.pop_at(i)
    %{db | memos: Map.put(db.memos, query, [{memo, db.revision} | rest])}
  end

  # `memo`'s height here, if every read it made gives here what it gave.
  defp holds(r, memo) do
    memo.reads
    |> Enum.reduce_while({{:ok, 0}, r}, fn
      {:input, key, value}, {{:ok, height}, r} ->
        if read_input(r.db, r.ctx, key) === value,
          do: {:cont, {{:ok, height}, r}},
          else: {:halt, {{:ok, nil}, r}}

      {:query, q, value}, {{:ok, height}, r} ->
        case ensure(r, q) do
          {{:ok, {now, h}}, r} when now.value === value -> {:cont, {{:ok, max(height, h)}, r}}
          {{:ok, _}, r} -> {:halt, {{:ok, nil}, r}}
          {{:error, _}, _} = err -> {:halt, err}
        end
    end)
    |> case do
      {{:ok, height}, r} when is_integer(height) -> {{:ok, height + 1}, r}
      other -> other
    end
  end

  # Compute `query`, recording what it reads, as its newest memo.
  defp compute(%Reads{} = r, query) do
    db = %{r.db | computes: Map.update(r.db.computes, query, 1, &(&1 + 1))}
    {value, inner} = db.mod.compute(query, %{r | db: db, reads: [], height: 0, failed: nil})
    db = inner.db

    case inner.failed do
      nil ->
        memo = %{value: value, reads: Enum.reverse(inner.reads)}
        kept = keep([{memo, db.revision} | Map.get(db.memos, query, [])], db)

        {{:ok, {memo, inner.height + 1}},
         %{r | db: %{db | memos: Map.put(db.memos, query, kept)}}}

      e ->
        {{:error, e}, %{r | db: db}}
    end
  end

  # Every memo used at this revision stays, and `versions` used before it.
  defp keep(kept, %{revision: revision, versions: versions}) do
    {kept, _} =
      Enum.flat_map_reduce(kept, versions, fn
        {_, ^revision} = m, older -> {[m], older}
        m, older when older > 0 -> {[m], older - 1}
        _, older -> {[], older}
      end)

    kept
  end

  # ---------- forgetting ----------

  defp filter_memos(memos, kept?) do
    Enum.reduce(memos, %{}, fn {q, kept}, acc ->
      case Enum.filter(kept, kept?) do
        [] -> acc
        kept -> Map.put(acc, q, kept)
      end
    end)
  end

  defp trim_memos(memos, held) do
    gives =
      Map.new(memos, fn {q, kept} -> {q, Enum.map(kept, fn {memo, _} -> memo.value end)} end)

    given? = fn
      {:input, _, _} ->
        true

      {:query, q, value} ->
        not MapSet.member?(held, q) or Enum.any?(Map.get(gives, q, []), &(&1 === value))
    end

    trimmed = filter_memos(memos, fn {memo, _} -> Enum.all?(memo.reads, given?) end)
    if count(trimmed) == count(memos), do: trimmed, else: trim_memos(trimmed, held)
  end

  defp count(memos), do: Enum.reduce(memos, 0, fn {_, kept}, n -> n + length(kept) end)
end
