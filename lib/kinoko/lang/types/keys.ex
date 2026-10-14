defmodule Kinoko.Lang.Types.Keys do
  @moduledoc """
  The map-key rule (ported from `types/check/keys.rs`): map keys must be
  data. A `Map`'s keys are compared and ordered, so a key may hold no
  function type, `Cmd` or `Html` at any depth (`holds_non_data?/1`, built on
  `Check.Decl.non_data?/1`). A map's value may. This is a Rust-only
  tightening: TS accepts any map key.

  `Check.Decl.forbid_in_model_field/3` refuses non-data anywhere in a
  variant's argument, so inside a deftype non-data reaches a key only
  through the deftype's parameters. The rule never instantiates a type.
  Instead it works out, for each deftype, which of its parameters reach a
  key (`settle/2`), and `D<args>` is bad when such a parameter's argument
  holds non-data. Each type walked is finite, so the rule ends however a
  deftype nests itself.

  A deftype's *group* is every name its variants apply, at any depth,
  itself included (builtins aside): the signatures its key positions were
  worked out from. A check that consults a deftype's key positions depends
  on its whole group, because a change anywhere in it can change the answer.
  So the check records the group in its `used`. Every other applied name the
  walk passes is looked up through `Ctx.dget/2`. TS has no map-key rule, so
  these group names are the only ones Rust's (and this port's) deps hold
  beyond TS's.

  The memo (`new/0`) depends on the signature table alone. A check keeps it
  in its `Ctx`.
  """

  alias Kinoko.Lang.Types.Check.{Ctx, Decl}
  alias Kinoko.Lang.Types.Extract

  @type reach :: %{reaching: [boolean()], names: MapSet.t(String.t())}

  @doc "An empty memo: nothing settled."
  def new, do: %{known: %{}, reaches: %{}}

  @doc """
  The group of `name` (a deftype's, as a rule) settled from `sigs`, a map or
  a lookup function: every name the map-key rule reads to work out which of
  its parameters reach a key, `name` included. A check that consults
  `name`'s key positions depends on exactly these names. Each signature is
  read once.
  """
  @spec reaching(String.t(), map() | (String.t() -> term())) :: MapSet.t(String.t())
  def reaching(name, sigs), do: settle(name, sigs).names

  @doc """
  `name`'s group settled from `sigs`: whether each of its parameters reaches
  a key (`[]` for a name that is no deftype), and the group's names
  (`reaching/2`).
  """
  @spec settle(String.t(), map() | (String.t() -> term())) :: reach()
  def settle(name, sigs) do
    {reach, _memo} = reach(new(), name, sigs)
    reach
  end

  @doc """
  Whether `t` holds a function type, `Cmd` or `Html` anywhere inside it
  (`Check.Decl.non_data?/1` at every depth): what a map key may not hold.
  """
  def holds_non_data?(t) do
    Decl.non_data?(t) or
      case t do
        {:applied, _, args} -> Enum.any?(args, &holds_non_data?/1)
        {:tuple, items} -> Enum.any?(items, &holds_non_data?/1)
        _ -> false
      end
  end

  @doc """
  Whether every `Map` key in `t` holds data: a `Map`'s own key, and each
  argument a deftype passes on to a key. Returns `{boolean, ctx}`. The walk
  goes on past a key that is not data (the answer is the same), so a failed
  check records every deftype too: a change behind any of them may be what
  it waits for.
  """
  def keys_are_data(ctx, {:arrow, params, ret}), do: all(ctx, params ++ [ret])
  def keys_are_data(ctx, {:tuple, items}), do: all(ctx, items)

  def keys_are_data(ctx, {:applied, name, args}) do
    key_is_data = not (name == "Map" and args != [] and holds_non_data?(hd(args)))
    non_data = Enum.map(args, &holds_non_data?/1)

    {passed_on, ctx} =
      if Enum.any?(non_data) do
        {reaching, ctx} = key_positions(ctx, name)

        ok =
          length(reaching) != length(args) or
            Enum.all?(Enum.zip(reaching, non_data), fn {reaches, non} ->
              not reaches or not non
            end)

        {ok, ctx}
      else
        {true, ctx}
      end

    ctx =
      if Map.has_key?(Extract.builtin_applied(), name) or MapSet.member?(ctx.used, name),
        do: ctx,
        else: ctx |> Ctx.dget(name) |> elem(1)

    {args_are, ctx} = all(ctx, args)
    {key_is_data and passed_on and args_are, ctx}
  end

  def keys_are_data(ctx, _named_or_var), do: {true, ctx}

  defp all(ctx, types) do
    Enum.reduce(types, {true, ctx}, fn t, {ok, ctx} ->
      {this, ctx} = keys_are_data(ctx, t)
      {ok and this, ctx}
    end)
  end

  # Whether each parameter of `name` reaches a key, its group recorded in
  # `used` (once per check); empty for a builtin, and for a name that is no
  # deftype. Consulted only where an argument holds non-data.
  defp key_positions(ctx, name) do
    if Map.has_key?(Extract.builtin_applied(), name) do
      {[], ctx}
    else
      {reach, keys} = reach(ctx.keys, name, ctx.sigs)
      ctx = %{ctx | keys: keys}

      ctx =
        if MapSet.member?(ctx.key_recorded, name),
          do: ctx,
          else: %{Ctx.record(ctx, reach.names) | key_recorded: MapSet.put(ctx.key_recorded, name)}

      {reach.reaching, ctx}
    end
  end

  @doc """
  `settle/2` against a memo (`new/0`) shared by every settle of one table:
  what is settled already is not worked out or read again. Returns
  `{reach, memo}`. A check threads its memo through its `Ctx`.
  """
  def reach(memo, name, sigs) when is_map(sigs), do: reach(memo, name, &Map.get(sigs, &1))

  def reach(memo, name, lookup) do
    case memo.reaches do
      %{^name => reach} ->
        {reach, memo}

      _ ->
        memo = if Map.has_key?(memo.known, name), do: memo, else: settle_group(memo, name, lookup)
        names = group(memo.known, [name], MapSet.new())
        reach = %{reaching: memo.known[name].reaching, names: names}
        {reach, %{memo | reaches: Map.put(memo.reaches, name, reach)}}
    end
  end

  defp group(_known, [], names), do: names

  defp group(known, [n | todo], names) do
    if MapSet.member?(names, n),
      do: group(known, todo, names),
      else: group(known, known[n].applies ++ todo, MapSet.put(names, n))
  end

  # ---------- settling a group ----------
  #
  # The least fixpoint of "a parameter reaches a key if a variant's argument
  # holds it inside a `Map`'s key, or inside an argument to a parameter that
  # reaches one", for `root` and every name its variants apply, at any depth,
  # not settled yet. The group is walked depth first along what each deftype
  # applies, and each deftype is worked out once, when its walk ends
  # (post-order). Where a parameter does not reach a key yet, the argument
  # passed to it waits on it, and is held the moment it does. So nothing is
  # worked out twice: the cost is linear in the size of the group's variants,
  # whatever their shape (a chain, a ring, a wide fan, a dense group).
  #
  # The flow is over the nodes of the members' variant arguments, each
  # member's in pre-order, the nodes inside one following it up to its
  # `end`. A node is held when a key would hold it; a member's parameter
  # reaches a key when a leaf naming it is held.

  defp settle_group(memo, root, lookup) do
    flow = %{
      # id => %{name, params, variants, applies (a tuple)}
      members: %{},
      ids: %{},
      # node index => end; kind; and the set of held indexes
      ends: %{},
      kinds: %{},
      held_nodes: MapSet.new(),
      count: 0,
      # id => MapSet of held leaf names
      held: %{},
      # id => %{param => [{id, node}]}
      waiting: %{},
      todo: []
    }

    {known, flow, walking} = enter(memo.known, flow, [], root, lookup)
    {known, flow} = walk(known, flow, walking, lookup)

    known =
      Enum.reduce(flow.members, known, fn {id, member}, known ->
        held = flow.held[id]
        reaching = Enum.map(member.params, &MapSet.member?(held, &1))
        Map.put(known, member.name, %{reaching: reaching, applies: Tuple.to_list(member.applies)})
      end)

    %{memo | known: known}
  end

  defp walk(known, flow, [], _lookup), do: {known, flow}

  defp walk(known, flow, [{id, next} | rest], lookup) do
    applies = flow.members[id].applies

    if next < tuple_size(applies) do
      {known, flow, walking} =
        enter(known, flow, [{id, next + 1} | rest], elem(applies, next), lookup)

      walk(known, flow, walking, lookup)
    else
      walk(known, work_out(flow, id, known), rest, lookup)
    end
  end

  # Starts walking `name`, unless it is settled or being walked already: a
  # deftype joins the group, and any other name is settled now, as passing
  # nothing on.
  defp enter(known, flow, walking, name, lookup) do
    if Map.has_key?(known, name) or Map.has_key?(flow.ids, name) do
      {known, flow, walking}
    else
      case lookup.(name) do
        {:type, params, variants} ->
          {id, flow} = join(flow, name, params, variants)
          {known, flow, [{id, 0} | walking]}

        _ ->
          {Map.put(known, name, %{reaching: [], applies: []}), flow, walking}
      end
    end
  end

  defp join(flow, name, params, variants) do
    applies =
      for {_, args} <- variants,
          a <- args,
          n <- applied(a, []),
          not Map.has_key?(Extract.builtin_applied(), n),
          into: MapSet.new(),
          do: n

    id = map_size(flow.members)

    member = %{
      name: name,
      params: params,
      variants: variants,
      applies: applies |> Enum.sort() |> List.to_tuple()
    }

    flow = %{
      flow
      | members: Map.put(flow.members, id, member),
        ids: Map.put(flow.ids, name, id),
        held: Map.put(flow.held, id, MapSet.new()),
        waiting: Map.put(flow.waiting, id, %{})
    }

    {id, flow}
  end

  # Each name `t` applies, at any depth.
  defp applied({:applied, name, args}, acc), do: Enum.reduce(args, [name | acc], &applied/2)
  defp applied({:arrow, ps, r}, acc), do: Enum.reduce([r | ps], acc, &applied/2)
  defp applied({:tuple, items}, acc), do: Enum.reduce(items, acc, &applied/2)
  defp applied(_, acc), do: acc

  # Works out member `id`, once every deftype it applies is (but those still
  # being walked): holds every node of its variants a key holds, and
  # releases what waits on its parameters that come to reach one.
  defp work_out(flow, id, known) do
    first = flow.count

    flow =
      for {_, args} <- flow.members[id].variants, a <- args, reduce: flow do
        flow -> flatten(flow, a)
      end

    flow =
      Enum.reduce(first..(flow.count - 1)//1, flow, fn at, flow ->
        case flow.kinds[at] do
          {:applied, name, arity} -> pass_arguments(flow, id, known, at, name, arity)
          _ -> flow
        end
      end)

    drain(flow)
  end

  # Where `name` is applied at node `at`: the argument to a parameter that
  # reaches a key (a settled deftype's, or a member's) is held now; the
  # argument to a member's parameter that does not yet waits on it.
  defp pass_arguments(flow, id, known, at, name, arity) do
    member =
      case flow.ids do
        %{^name => m} -> if length(flow.members[m].params) == arity, do: m
        _ -> nil
      end

    settled =
      case known do
        %{^name => %{reaching: r}} when length(r) == arity -> List.to_tuple(r)
        _ -> nil
      end

    params = if member, do: List.to_tuple(flow.members[member].params)

    {flow, _} =
      Enum.reduce(0..(arity - 1)//1, {flow, at + 1}, fn i, {flow, arg} ->
        flow =
          if (i == 0 and name == "Map") or (settled != nil and elem(settled, i)),
            do: %{flow | todo: [{id, arg} | flow.todo]},
            else: flow

        flow =
          if member do
            param = elem(params, i)

            if MapSet.member?(flow.held[member], param) do
              %{flow | todo: [{id, arg} | flow.todo]}
            else
              waiting =
                Map.update!(flow.waiting, member, fn w ->
                  Map.update(w, param, [{id, arg}], &[{id, arg} | &1])
                end)

              %{flow | waiting: waiting}
            end
          else
            flow
          end

        {flow, flow.ends[arg]}
      end)

    flow
  end

  # Adds `t`'s nodes, in pre-order.
  defp flatten(flow, t) do
    at = flow.count

    kind =
      case t do
        {:named, n} -> {:leaf, n}
        {:var, n} -> {:leaf, n}
        {:applied, n, args} -> {:applied, n, length(args)}
        _ -> :other
      end

    flow = %{flow | kinds: Map.put(flow.kinds, at, kind), count: at + 1}

    flow =
      case t do
        {:applied, _, items} -> Enum.reduce(items, flow, &flatten(&2, &1))
        {:tuple, items} -> Enum.reduce(items, flow, &flatten(&2, &1))
        {:arrow, ps, r} -> Enum.reduce(ps ++ [r], flow, &flatten(&2, &1))
        _ -> flow
      end

    %{flow | ends: Map.put(flow.ends, at, flow.count)}
  end

  defp drain(%{todo: []} = flow), do: flow

  defp drain(%{todo: [{id, at} | rest]} = flow) do
    flow = %{flow | todo: rest}
    drain(hold(flow, id, at, flow.ends[at]))
  end

  # Holds node `node` of member `id` and every node up to `stop`. A node
  # already held has every node inside it held, and is passed over. A name
  # the member comes to hold releases the arguments waiting on it.
  defp hold(flow, _id, node, stop) when node >= stop, do: flow

  defp hold(flow, id, node, stop) do
    if MapSet.member?(flow.held_nodes, node) do
      hold(flow, id, flow.ends[node], stop)
    else
      flow = %{flow | held_nodes: MapSet.put(flow.held_nodes, node)}

      flow =
        case flow.kinds[node] do
          {:leaf, name} ->
            if MapSet.member?(flow.held[id], name) do
              flow
            else
              {released, waiting} = Map.pop(flow.waiting[id], name, [])

              %{
                flow
                | held: Map.update!(flow.held, id, &MapSet.put(&1, name)),
                  waiting: Map.put(flow.waiting, id, waiting),
                  todo: released ++ flow.todo
              }
            end

          _ ->
            flow
        end

      hold(flow, id, node + 1, stop)
    end
  end
end
