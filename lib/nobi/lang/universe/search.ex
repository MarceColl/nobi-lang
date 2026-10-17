defmodule Nobi.Lang.Universe.Search do
  @moduledoc """
  The search for what to promote (ported from `universe/search.rs`), from
  <https://dziban.net/posts/yabu-incremental-type-system/>.

  Before a change nothing staged could promote, so a set that can now must
  reach the change, the root: the patch just staged, or `""` for the names
  the last round promoted. Two patches are linked when some declaration's
  check depends on both (`links/2`). Without the root the links fall into
  components (`parts/2`); each is searched on its own, over the sets
  connected to the root, checking only the declarations that depend on it,
  and the largest set of every component promotes together.

  Two prunings keep it from listing sets that can never promote: a patch
  that fails in every set holding it is left out first (`alive`), and a set
  is grown only while its patches merge. Copies of one patch under several
  ids are tried as one, as the best set holds them all. The tests check this
  against trying every subset (`Nobi.Lang.NaiveUniverse`).

  Sets of ids are `MapSet`s; whatever their order decides is taken in id
  order, as Rust's `BTreeSet`.
  """

  alias Nobi.Lang.Universe
  alias Nobi.Lang.Universe.Db

  @change ""

  @doc """
  The largest set of staged patches that can promote now, among those
  reaching `root`, and its checks (`%{name => outcome}`); or `nil`. Returns
  `{nil | {ids, checks}, u}`.
  """
  def search(u, root, changed) do
    {links, u} = links(u, changed)
    {graph, parts} = parts(root, links)

    result =
      Enum.reduce_while(parts, {{MapSet.new(), %{}}, u}, fn {within, scope},
                                                            {{best, checks}, u} ->
        {within, u} = alive(u, within, scope)

        # `alive` can drop the root itself: it is dead, so no set this part
        # would try (every one holds the root) can promote.
        if root != @change and not MapSet.member?(within, root) do
          {:halt, {nil, u}}
        else
          copies = copies(u.staged, within)
          sets = connected(graph, root, within, copies, &(merge(u.staged, &1) != nil))

          case first_typechecking(u, sets, scope) do
            {nil, u} -> {:halt, {nil, u}}
            {{ids, part}, u} -> {:cont, {{MapSet.union(best, ids), Map.merge(checks, part)}, u}}
          end
        end
      end)

    case result do
      {nil, u} ->
        {nil, u}

      {{best, checks}, u} ->
        best = MapSet.delete(best, @change)
        {if(MapSet.size(best) == 0, do: nil, else: {best, checks}), u}
    end
  end

  defp first_typechecking(u, sets, scope) do
    Enum.reduce_while(sets, {nil, u}, fn ids, {nil, u} ->
      case typechecks(u, ids, scope) do
        {nil, u} -> {:cont, {nil, u}}
        {checks, u} -> {:halt, {{ids, checks}, u}}
      end
    end)
  end

  # The patches of `within` that could still promote with others of it,
  # `scope` the names its part checks. One cannot when a declaration of the
  # scope, its own or a committed one it breaks, fails over it alone, and its
  # name and every name its check depends on are touched by no other patch of
  # `within` (copies of it aside): it fails in every set holding the patch.
  # Dropping one can leave others so, until none is. A check's dependencies
  # leave out stdlib names, so when a patch defines one, none is dropped.
  defp alive(u, within, scope) do
    patches = for id <- Enum.sort(within), patch = u.staged[id], patch != nil, do: {id, patch}

    if Enum.any?(patches, fn {_, patch} -> Universe.defines_stdlib?(patch) end) do
      {within, u}
    else
      {failing, u} =
        Enum.map_reduce(patches, u, fn {id, patch}, u ->
          ctx = Db.ctx([id])
          own = for {:live, _, _, _} = e <- patch, do: e

          code =
            Enum.filter(
              own ++ Universe.dependents(u.committed, patch),
              &(Universe.entry_name(&1) in scope)
            )

          Enum.flat_map_reduce(code, u, fn {:live, name, cid, decl}, u ->
            {o, u} = checked(u, ctx, cid, decl)
            {if(o.typed == nil and not o.internal, do: [MapSet.put(o.deps, name)], else: []), u}
          end)
        end)

      {prune(Enum.zip(patches, failing), within), u}
    end
  end

  defp prune(patches, within) do
    touchers =
      for {{id, patch}, _} <- patches, MapSet.member?(within, id), e <- patch, reduce: %{} do
        acc -> Map.update(acc, Universe.entry_name(e), [{id, patch}], &[{id, patch} | &1])
      end

    others? = fn id, patch, n ->
      Enum.any?(Map.get(touchers, n, []), fn {j, p} -> j != id and not same?(p, patch) end)
    end

    dead =
      for {{id, patch}, fails} <- patches,
          MapSet.member?(within, id),
          Enum.any?(fails, fn names -> not Enum.any?(names, &others?.(id, patch, &1)) end),
          do: id

    if dead == [], do: within, else: prune(patches, MapSet.difference(within, MapSet.new(dead)))
  end

  @doc false
  # The graph `links` make between patches, and the independent parts of the
  # search: each component the root's links fall into once the root is
  # removed (with the root), and the names whose checks depend only on it.
  def parts(root, links) do
    graph =
      for {_, ids} <- links, a <- ids, reduce: %{} do
        graph ->
          Map.update(graph, a, MapSet.delete(ids, a), &MapSet.union(&1, MapSet.delete(ids, a)))
      end

    components =
      graph
      |> Map.get(root, MapSet.new())
      |> Enum.sort()
      |> Enum.reduce([], fn start, components ->
        if Enum.any?(components, &MapSet.member?(&1, start)),
          do: components,
          else: components ++ [reach(graph, start, root)]
      end)

    components = if components == [], do: [MapSet.new()], else: components

    parts =
      Enum.map(components, fn within ->
        within = MapSet.put(within, root)

        scope =
          for {n, l} <- links,
              MapSet.size(l) > 0,
              MapSet.subset?(l, within),
              into: MapSet.new(),
              do: n

        {within, scope}
      end)

    {graph, parts}
  end

  @doc false
  # For every name, the patches its check can depend on: those defining or
  # removing it or a name some version of it depends on, and `""` if any of
  # those names just promoted. A staged declaration's dependencies are those
  # of its check over committed code with its own patch applied. A tombstone
  # has no check: its name links it, as a declaration's does, and so does
  # every declaration that consulted the name. Over a patch, a committed
  # declaration it can break may consult names it does not over committed
  # code (the map-key rule walks what a deftype the patch changes comes to
  # apply): those link it too.
  def links(u, changed) do
    definers =
      for {id, patch} <- u.staged, e <- patch, reduce: %{} do
        acc -> Map.update(acc, Universe.entry_name(e), MapSet.new([id]), &MapSet.put(&1, id))
      end

    link = fn links, name, deps ->
      l =
        Enum.reduce([name | MapSet.to_list(deps)], Map.get(links, name, MapSet.new()), fn n, l ->
          l = MapSet.union(l, Map.get(definers, n, MapSet.new()))
          if MapSet.member?(changed, n), do: MapSet.put(l, @change), else: l
        end)

      Map.put(links, name, l)
    end

    links = Enum.reduce(u.committed, %{}, fn {name, c}, links -> link.(links, name, c.deps) end)

    Enum.reduce(Enum.sort(u.staged), {links, u}, fn {id, patch}, {links, u} ->
      ctx = Db.ctx([id])
      code = for({:live, _, _, _} = e <- patch, do: e) ++ Universe.dependents(u.committed, patch)

      {links, u} =
        Enum.reduce(code, {links, u}, fn {:live, name, cid, decl}, {links, u} ->
          {o, u} = checked(u, ctx, cid, decl)
          {link.(links, name, o.deps), u}
        end)

      links =
        for(
          {:gone, name} <- patch,
          reduce: links,
          do: (links -> link.(links, name, MapSet.new()))
        )

      {links, u}
    end)
  end

  # What checking gives every declaration `scope` names, once the patches in
  # `ids` are applied over committed code; nil if one does not typecheck, or
  # the patches cannot merge.
  defp typechecks(u, ids, scope) do
    case merge(u.staged, ids) do
      nil ->
        {nil, u}

      merged ->
        ctx = Db.ctx(Enum.filter(ids, &Map.has_key?(u.staged, &1)))

        Enum.reduce_while(Enum.sort(scope), {%{}, u}, fn name, {checks, u} ->
          d =
            case merged do
              %{^name => {:live, _, _, _} = e} -> e
              %{^name => {:gone, _}} -> nil
              _ -> if c = u.committed[name], do: Universe.declared(name, c)
            end

          case d do
            nil ->
              {:cont, {checks, u}}

            {:live, _, cid, decl} ->
              case checked(u, ctx, cid, decl) do
                {%{typed: nil}, u} -> {:halt, {nil, u}}
                {o, u} -> {:cont, {Map.put(checks, name, o), u}}
              end
          end
        end)
    end
  end

  defp checked(u, ctx, cid, decl) do
    {o, salsa} = Db.checked(u.salsa, ctx, cid, decl)
    {o, %{u | salsa: salsa}}
  end

  @doc false
  # What the patches in `ids` apply together, by name (the spec's `merge`);
  # nil if two of them touch the same name (the spec's `disjoint`, where the
  # same patch under two ids is one patch), or one touches a name twice.
  def merge(staged, ids) do
    ids
    |> Enum.sort()
    |> Enum.filter(&Map.has_key?(staged, &1))
    |> Enum.reduce_while(%{}, fn id, merged ->
      case merge_patch(staged, id, staged[id], merged) do
        nil -> {:halt, nil}
        merged -> {:cont, merged}
      end
    end)
    |> case do
      nil -> nil
      merged -> Map.new(merged, fn {n, {e, _}} -> {n, e} end)
    end
  end

  defp merge_patch(_staged, _id, [], merged), do: merged

  defp merge_patch(staged, id, [e | rest], merged) do
    name = Universe.entry_name(e)

    case merged do
      %{^name => {_, ^id}} -> nil
      %{^name => {_, j}} -> if same?(staged[j], staged[id]), do: merged, else: nil
      _ -> merge_patch(staged, id, rest, Map.put(merged, name, {e, id}))
    end
  end

  # Everything reachable from `start` without passing through `root`.
  defp reach(graph, start, root), do: reach(graph, [start], root, MapSet.new([start]))

  defp reach(_graph, [], _root, seen), do: seen

  defp reach(graph, [n | todo], root, seen) do
    {todo, seen} =
      graph
      |> Map.get(n, MapSet.new())
      |> Enum.reduce({todo, seen}, fn m, {todo, seen} ->
        if m == root or MapSet.member?(seen, m),
          do: {todo, seen},
          else: {[m | todo], MapSet.put(seen, m)}
      end)

    reach(graph, todo, root, seen)
  end

  @doc false
  # Every set inside `within` that holds `root`, is connected and `merges?`,
  # and holds every copy (`copies`) of each patch it holds, best first. A set
  # that does not merge has no superset that does, so one is never grown:
  # every set that merges is still reached, through sets inside it.
  def connected(graph, root, within, copies, merges?) do
    unit = fn id -> Map.get(copies, id, MapSet.new([id])) end
    found = Enum.filter([unit.(root)], merges?)
    found = grow(graph, within, unit, merges?, found, MapSet.new(found))
    found |> MapSet.to_list() |> Enum.sort_by(&rank/1, :desc)
  end

  defp grow(_graph, _within, _unit, _merges?, [], found), do: found

  defp grow(graph, within, unit, merges?, [ids | todo], found) do
    {todo, found} =
      ids
      |> Enum.flat_map(&Enum.to_list(Map.get(graph, &1, MapSet.new())))
      |> Enum.reduce({todo, found}, fn n, {todo, found} ->
        more =
          if MapSet.member?(within, n) and not MapSet.member?(ids, n),
            do: MapSet.union(ids, unit.(n))

        if more != nil and not MapSet.member?(found, more) and merges?.(more),
          do: {[more | todo], MapSet.put(found, more)},
          else: {todo, found}
      end)

    grow(graph, within, unit, merges?, todo, found)
  end

  @doc false
  # Larger sets first; between equal sizes, the spec's `score`: the set
  # holding the greater id where they first differ, from the top.
  def rank(ids), do: {MapSet.size(ids), Enum.sort(ids, :desc)}

  # Each staged patch of `within`, by id, and the ids of `within` that stage
  # the same patch, its own among them.
  defp copies(staged, within) do
    within
    |> Enum.sort()
    |> Enum.filter(&Map.has_key?(staged, &1))
    |> Enum.reduce([], fn id, classes ->
      case Enum.find_index(classes, fn {p, _} -> same?(p, staged[id]) end) do
        nil -> classes ++ [{staged[id], MapSet.new([id])}]
        i -> List.update_at(classes, i, fn {p, ids} -> {p, MapSet.put(ids, id)} end)
      end
    end)
    |> Enum.flat_map(fn {_, ids} -> Enum.map(ids, &{&1, ids}) end)
    |> Map.new()
  end

  @doc false
  # Whether two patches are the same patch: the same entry for every name.
  def same?(a, b), do: length(a) == length(b) and by_name(a) == by_name(b)

  defp by_name(patch) do
    Map.new(patch, fn
      {:live, name, cid, _} -> {name, cid}
      {:gone, name} -> {name, :gone}
    end)
  end
end
