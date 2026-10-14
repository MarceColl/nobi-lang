defmodule Kinoko.Lang.Universe.Db do
  @moduledoc """
  The database every check goes through (ported from `universe/db.rs`):
  committed code and each staged patch are layers of its inputs, and a check
  is kept by what it read.

  ## Inputs

  - layer `:committed` and layer `{:patch, id}`: `{:name, name}` gives the
    CID of the declaration the layer holds under `name`, or `:tombstone`
    where a patch removes it.
  - layer `:cas`: `{:decl, cid}` gives `{cid, decl}`, every staged and
    committed declaration by CID (positions dropped). It is the last layer
    of every context, and no other layer holds its keys.

  A context is `ctx/1` of the patches tried: each over committed code.

  ## Queries

  - `{:signature, cid}`: the declaration's signature. It reads its `:cas`
    entry alone, so it is worked out once per CID, whatever asks.
  - `{:sig, name}`: the signature `name` has in a context: its
    declaration's there, or the stdlib's when the context has none.
  - `{:reaching, name}`: `name`'s deftype group settled (`Keys.settle/2`),
    each of its names' signatures read through `{:sig, _}`, never through
    another `{:reaching, _}` (so a ring of deftypes is no cycle). Every check
    that consults the group reads this one memo, not every signature in it.
  - `{:check, cid}`: the declaration checked against the signatures it
    looks up, each read through `{:sig, _}`, and the groups whose key
    positions it consults, each through `{:reaching, _}`: so it is kept
    wherever those are the same.

  `Kinoko.Lang.Types.Check` takes a lookup function, which cannot thread
  the reads: the check runs against `Salsa.peek/2` and then records a read
  of exactly what it consulted (`looked_up` and `groups`). Raises if the
  check consulted a name those reads do not cover (Rust's debug assert):
  its memo would then be reused where it no longer holds.

  A check's value is an outcome, never its messages: what one says of an
  unbound name reads the whole table, not one name's signature. Domain
  errors here are `{:error, {:missing, cid}}`, never the salsa's own shapes.
  """

  @behaviour Kinoko.Lang.Salsa

  alias Kinoko.Lang.Salsa
  alias Kinoko.Lang.Types.{Check, Extract, Keys, Stdlib}

  @typedoc """
  A check as the database keeps it: its checked tree if it typechecks, the
  names it depends on (`deps/2`), and whether it failed on the checker's own
  fault (`"internal"`).
  """
  @type outcome :: %{typed: term() | nil, deps: MapSet.t(String.t()), internal: boolean()}

  @doc "The context of a trial of the patches `ids`: each over committed code, then the CAS."
  @spec ctx(Enumerable.t()) :: [term()]
  def ctx(ids), do: Enum.map(Enum.sort(ids), &{:patch, &1}) ++ [:committed, :cas]

  @impl true
  def compute({:signature, cid}, r) do
    case Salsa.input(r, {:decl, cid}) do
      {{_, decl}, r} -> {{:ok, Extract.signature(decl)}, r}
      {nil, r} -> {{:error, {:missing, cid}}, r}
    end
  end

  def compute({:sig, name}, r) do
    case Salsa.input(r, {:name, name}) do
      {nil, r} -> {{:ok, Map.get(Stdlib.signatures(), name)}, r}
      {cid, r} -> Salsa.ask(r, {:signature, cid})
    end
  end

  def compute({:reaching, name}, r) do
    reach = Keys.settle(name, lookup(r))
    {{:ok, reach}, record_sigs(r, reach.names)}
  end

  def compute({:check, cid}, r) do
    case Salsa.input(r, {:decl, cid}) do
      {{_, decl}, r} -> check(decl, r)
      {nil, r} -> {{:error, {:missing, cid}}, r}
    end
  end

  defp check(decl, r) do
    checked = Check.decl(decl, lookup(r))

    {reached, r} =
      checked.groups
      |> Enum.sort()
      |> Enum.reduce({MapSet.new(), r}, fn group, {reached, r} ->
        case Salsa.ask(r, {:reaching, group}) do
          {{:ok, reach}, r} -> {MapSet.union(reached, reach.names), r}
          {_, r} -> {reached, r}
        end
      end)

    r = record_sigs(r, checked.looked_up)
    read = MapSet.union(reached, checked.looked_up)

    unless MapSet.subset?(checked.deps, read) do
      raise "#{Kinoko.Lang.Ast.name(decl)}: consulted #{inspect(MapSet.to_list(checked.deps))}, " <>
              "read #{inspect(MapSet.to_list(read))}"
    end

    {typed, internal} =
      case checked.result do
        {:ok, typed} -> {typed, false}
        {:error, errors} -> {nil, Enum.any?(errors, &(&1.code == "internal"))}
      end

    {{:ok, %{typed: typed, deps: deps(decl, checked), internal: internal}}, r}
  end

  # What a name's signature is in this context, unrecorded: the caller
  # records a read of every name it hands this to.
  defp lookup(r) do
    fn name ->
      case Salsa.peek(r, {:name, name}) do
        nil ->
          Map.get(Stdlib.signatures(), name)

        cid ->
          case Salsa.peek(r, {:decl, cid}) do
            {_, decl} -> Extract.signature(decl)
            nil -> nil
          end
      end
    end
  end

  defp record_sigs(r, names) do
    names
    |> Enum.sort()
    |> Enum.reduce(r, fn name, r -> r |> Salsa.ask({:sig, name}) |> elem(1) end)
  end

  @doc """
  `decl` (whose CID is `cid`) checked in `ctx`, through the database:
  `{outcome, db}`. A check that failed on the checker's own fault is never
  kept: asked again, it runs again. A salsa error (never: a check reads
  signatures, which read nothing but inputs) is an internal failure.
  """
  @spec checked(Salsa.t(), [term()], String.t(), term()) :: {outcome(), Salsa.t()}
  def checked(db, ctx, cid, decl) do
    query = {:check, cid}

    case Salsa.query(db, ctx, query) do
      {{:ok, %{internal: true} = outcome}, db} ->
        {outcome, Salsa.retain(db, &(&1 != query))}

      {{:ok, outcome}, db} ->
        {outcome, db}

      {{:error, _}, db} ->
        failed = %{deps: MapSet.new(), result: {:error, []}}
        {%{typed: nil, deps: deps(decl, failed), internal: true}, db}
    end
  end

  @doc "The signature of the declaration `cid` names, through the database: worked out once per CID."
  @spec signature(Salsa.t(), String.t()) :: {term(), Salsa.t()}
  def signature(db, cid) do
    {{:ok, sig}, db} = Salsa.query(db, [:cas], {:signature, cid})
    {sig, db}
  end

  @doc """
  The names `decl`'s check depends on that a patch could define: what the
  check consulted and, when it failed, what `decl` names too (a failed check
  stops looking early; TS's `depsOf`). No patch defines a stdlib name or a
  builtin.
  """
  @spec deps(term(), %{deps: MapSet.t(String.t()), result: term()}) :: MapSet.t(String.t())
  def deps(decl, checked) do
    deps =
      case checked.result do
        {:ok, _} -> checked.deps
        {:error, _} -> MapSet.union(checked.deps, Extract.deps(decl))
      end

    MapSet.reject(deps, fn n ->
      Map.has_key?(Stdlib.signatures(), n) or n in Extract.builtin_named() or
        Map.has_key?(Extract.builtin_applied(), n)
    end)
  end
end
