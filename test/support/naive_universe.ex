defmodule Kinoko.Lang.NaiveUniverse do
  @moduledoc """
  The universe's reference (Rust's `stage_naive` and friends in
  `universe/tests.rs`): every subset of the staged patches, largest first
  (the spec's `settle`), every check afresh against a table built for it,
  and so are its reasons. Its database only follows what is staged and
  committed; it never checks through it.
  """

  alias Kinoko.Lang.Types.{Check, Evolution, Extract, Stdlib}
  alias Kinoko.Lang.Universe
  alias Kinoko.Lang.Universe.{Db, Search}

  def new, do: Universe.new()

  def unstage(u, id), do: Universe.unstage(u, id)

  @doc "Stage `entries` under `id`, then promote what trying every subset picks."
  def stage(u, id, entries) do
    u = Universe.put(u, id, entries)

    {promoted, u} =
      Universe.settle(u, id, fn u, _root, _changed ->
        case every_promotable(u) do
          [] -> {nil, u}
          [ids | _] -> {{ids, afresh(u, ids)}, u}
        end
      end)

    verdict =
      if id in promoted,
        do: {:promoted, promoted},
        else: {:staged, reasons(Universe.committed(u), Universe.staged(u)[id])}

    {u, verdict}
  end

  @doc "Every non-empty set of staged patches that could promote now, best first, checked afresh."
  def every_promotable(u) do
    ids = u.staged |> Map.keys() |> Enum.sort()
    n = length(ids)

    for bits <- 1..(Bitwise.bsl(1, n) - 1)//1,
        set =
          for(
            {id, i} <- Enum.with_index(ids),
            Bitwise.band(Bitwise.bsr(bits, i), 1) == 1,
            into: MapSet.new(),
            do: id
          ),
        afresh(u, set) != nil do
      set
    end
    |> Enum.sort_by(&Search.rank/1, :desc)
  end

  @doc """
  What checking afresh gives every declaration committed code holds once the
  patches in `ids` are applied over it, each against the whole table; nil if
  one does not typecheck, or the patches cannot merge.
  """
  def afresh(u, ids) do
    case Search.merge(u.staged, ids) do
      nil ->
        nil

      merged ->
        code = patched(u.committed, Map.values(merged))

        changes =
          Enum.map(merged, fn
            {name, {:live, _, _, decl}} -> {name, Extract.signature(decl)}
            {name, {:gone, _}} -> {name, nil}
          end)

        sigs = Universe.over(u.sigs, changes)

        Enum.reduce_while(code, %{}, fn {name, {:live, _, _, decl}}, checks ->
          checked = Check.decl(decl, sigs)

          case {checked.result, evolution(u.committed, name, decl)} do
            {{:ok, typed}, []} ->
              outcome = %{typed: typed, deps: Db.deps(decl, checked), internal: false}
              {:cont, Map.put(checks, name, outcome)}

            _ ->
              {:halt, nil}
          end
        end)
    end
  end

  @doc """
  Why `entries` cannot promote over `committed`, checked afresh: one reason
  per error of each declaration that does not typecheck. `[]` means it can.
  The reference for `Universe.reasons/2`.
  """
  def reasons(committed, entries) do
    patch = Enum.map(entries, &Universe.internal/1)

    case Universe.twice(patch) do
      [] ->
        code = patched(committed, patch)

        sigs =
          Map.merge(
            Stdlib.signatures(),
            Map.new(code, fn {n, {:live, _, _, d}} -> {n, Extract.signature(d)} end)
          )

        code
        |> Enum.sort()
        |> Enum.flat_map(fn {name, {:live, _, _, decl}} ->
          errors =
            case Check.decl(decl, sigs).result do
              {:ok, _} -> []
              {:error, errors} -> errors
            end

          Enum.map(
            errors ++ evolution(committed, name, decl),
            &%{name: name, code: &1.code, message: &1.message}
          )
        end)

      twice ->
        twice
    end
  end

  # The model evolution rule's errors for `decl` against what is committed
  # under `name` (`[]` for anything but a model).
  defp evolution(committed, name, {:defmodel, _, _} = decl) do
    old = with %{decl: d} <- committed[name], do: Extract.signature(d)
    Evolution.errors(name, old, Extract.signature(decl))
  end

  defp evolution(_committed, _name, _decl), do: []

  # Committed code with `patch` applied over it, by name.
  defp patched(committed, patch) do
    code = Map.new(committed, fn {n, c} -> {n, Universe.declared(n, c)} end)

    Enum.reduce(patch, code, fn
      {:live, name, _, _} = e, code -> Map.put(code, name, e)
      {:gone, name}, code -> Map.delete(code, name)
    end)
  end
end
