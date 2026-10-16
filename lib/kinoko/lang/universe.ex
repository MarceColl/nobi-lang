defmodule Kinoko.Lang.Universe do
  @moduledoc """
  The universe (ported from `universe/mod.rs`; `specs/universe/universe.qnt`
  holds its invariants): committed code changes only by whole sets of staged
  patches that typecheck together, and once a change settles, no non-empty
  set of staged patches could promote. A patch defines names and removes
  them (tombstones). Every promoted round is one entry of an append-only
  history; committed code is what replaying it builds, kept as it goes.

  Finding what to promote is `Kinoko.Lang.Universe.Search`. Every check goes
  through a salsa (`Kinoko.Lang.Universe.Db`): committed code is one layer
  of its inputs and each staged patch another, so a trial is a context: its
  patches over committed code. A declaration is checked by its CID, reading
  the signature of each name it consults through the database, so its memo
  serves every context where those signatures are the same: an edit that
  keeps a declaration's signature never checks its dependents again.

  What a check says is kept as a check against the database's lookup words
  it; what an unbound name says is worded again from the whole signature
  table (`signatures/1`: the stdlib's and committed code's, the patch over
  them),
  built once per staging that needs it (`Kinoko.Lang.Types.Hints.reword/2`).
  So a failing declaration is checked once, through the database, never
  again for its messages.

  A universe is a value; every operation returns the new one.

  ## Stored models evolve add-only

  A `defmodel` staged over a committed stored model (one with `id : Uuid`)
  must keep every committed field with its type, and add only `Option` or
  defaulted fields (`Kinoko.Lang.Types.Evolution`); otherwise its check
  fails with `"model-evolution"` reasons and the patch stays staged. The
  committed version is read through the database (`{:committed, name}`,
  which only committed code's layer holds), so the rule is part of the
  model's memoized check. `restore/3` checks committed code with nothing
  committed before it, so a restore never trips the rule.

  ## Degraded

  `restore/3` rebuilds committed code from storage and checks it again. When
  it no longer typechecks (the checker changed under stored code), the
  universe is restored *degraded* rather than refused: committed code is
  kept exactly as stored, its failing declarations unchecked (`typed: nil`),
  and `degraded/1` gives the reasons. Staging, unstaging and reading work as
  ever, but while degraded a patch promotes only when the whole image, every
  committed declaration with the patch applied over it, typechecks; its
  reasons are the image's. The first round that promotes leaves the universe
  sound again, and every staged patch is tried anew.

  Other pieces of Kinoko go through `Kinoko.Lang`, never through this
  module: its documented functions back the façade, and the `@doc false`
  ones are the promotion search's (`Kinoko.Lang.Universe.Search`) and the
  tests' alone.

  ## Shapes

  - entry: `{:live, decl} | {:gone, name}`, what a patch does to one name.
  - round: `%{ids: [id], entries: [{:live, name, cid} | {:gone, name}]}`,
    ids sorted, entries one per name in name order. It holds no
    declaration, and the universe keeps no text: a declaration's canonical
    text is `Kinoko.Lang.Format.decl/1` of it, and one superseded since
    lives on only where the caller keeps it (the CAS, `Kinoko.Cas`).
  - verdict: `{:promoted, [id]}` (every patch that promoted as a result, in
    order) or `{:staged, [reason]}`.
  - reason: `%{name: String.t() | nil, code: String.t(), message: String.t()}`,
    one per error of each declaration that does not typecheck once the
    patch is applied over committed code (its own, or a committed one it
    breaks or removes a name from, `name` then that one's), in name order.
    Besides the checker's codes: `"duplicate"` (a name touched twice in one
    patch), `"bad-id"` (the empty id), and, from `restore/3`, `"restore"`
    (storage that is not what history replays to).
  - durable: `%{commits: [round], staged: [{id, [{name, cid | :gone}]}]}`
    (`durable/1`), staged patches in the order they were (last) staged.

  Inside, a staged entry is `{:live, name, cid, decl} | {:gone, name}`, its
  CID worked out once, when it was staged, and its declaration without
  positions (`Kinoko.Lang.Ast.without_positions/1`), so a declaration is
  equal to itself parsed from anywhere, as in Rust. `staged/1` gives back
  what was staged.
  """

  alias Kinoko.Lang.{Ast, Cid, Salsa}
  alias Kinoko.Lang.Types.{Hints, Stdlib}
  alias Kinoko.Lang.Universe.{Db, Search}

  defstruct history: [],
            committed: %{},
            staged: %{},
            given: %{},
            order: [],
            # Committed code's signatures only: the stdlib is read live
            # (`signatures/1`), so a universe built before an upgrade sees
            # the stdlib as it is now.
            sigs: %{},
            salsa: nil,
            cas: MapSet.new(),
            kept: 0,
            degraded: nil

  @type t :: %__MODULE__{}
  @type id :: String.t()
  @type entry :: {:live, Ast.decl()} | {:gone, String.t()}
  @type applied :: {:live, String.t(), String.t()} | {:gone, String.t()}
  @type round :: %{ids: [id], entries: [applied]}
  @type reason :: %{name: String.t() | nil, code: String.t(), message: String.t()}
  @type verdict :: {:promoted, [id]} | {:staged, [reason]}

  # The root after a promotion: the names that just promoted. Never a patch
  # id: `stage/3` refuses the empty one.
  @change ""
  @no_id "a patch needs an id: the empty one names what a promotion changed"
  # The one patch `restore/3` checks committed code as. Its round is never
  # kept: the history restored takes its place.
  @restore "$restore"
  # A check through the database that failed and kept no error: only a
  # salsa error (never; the tests fail on it), so the patch still has a
  # reason to stay.
  @no_error "its check through the database failed without an error"

  @doc "An empty universe: nothing committed, staged or promoted."
  @spec new() :: t()
  def new, do: %__MODULE__{salsa: Salsa.new(Db)}

  @doc "Every promoted round, oldest first. Only ever appended to."
  @spec history(t()) :: [round]
  def history(%__MODULE__{history: history}), do: Enum.reverse(history)

  @doc "Committed code: `%{name => %{cid, decl, typed, deps}}`, each as checked against it."
  @spec committed(t()) :: %{String.t() => map()}
  def committed(%__MODULE__{committed: committed}), do: committed

  @doc "What each staged patch holds, as it was staged."
  @spec staged(t()) :: %{id => [entry]}
  def staged(%__MODULE__{given: given}), do: given

  @doc """
  `nil`, or the reasons committed code does not typecheck: the universe was
  restored degraded (see "Degraded") and nothing has promoted since.
  """
  @spec degraded(t()) :: [reason] | nil
  def degraded(%__MODULE__{degraded: degraded}), do: degraded

  @doc """
  The stdlib's signatures and committed code's. The stdlib's are the live
  table's: no committed name is in a stdlib namespace (they are reserved),
  so the stdlib's rows replace only stale copies of themselves.
  """
  @spec signatures(t()) :: map()
  def signatures(%__MODULE__{sigs: sigs}), do: Map.merge(sigs, Stdlib.signatures())

  @doc """
  What storage keeps (see "Shapes"): history and each staged patch's names
  and CIDs, patches in the order they were last staged. Nothing else: no
  declaration and no text.
  """
  @spec durable(t()) :: %{commits: [round], staged: [{id, [{String.t(), String.t() | :gone}]}]}
  def durable(%__MODULE__{} = u) do
    staged =
      for id <- Enum.reverse(u.order) do
        {id,
         Enum.map(Map.fetch!(u.staged, id), fn
           {:live, name, cid, _} -> {name, cid}
           {:gone, name} -> {name, :gone}
         end)}
      end

    %{commits: history(u), staged: staged}
  end

  @doc """
  How many times the database has checked a declaration, over this
  universe's life: the salsa's running `:check` counter (`Salsa.computed/2`).
  """
  @spec check_count(t()) :: non_neg_integer()
  def check_count(%__MODULE__{salsa: salsa}), do: Salsa.computed(salsa, :check)

  @doc "The code `rounds` (oldest first) build, each name's declaration by CID."
  @spec replay([round]) :: %{String.t() => String.t()}
  def replay(rounds) do
    for round <- rounds, entry <- round.entries, reduce: %{} do
      code ->
        case entry do
          {:live, name, cid} -> Map.put(code, name, cid)
          {:gone, name} -> Map.delete(code, name)
        end
    end
  end

  @doc """
  Stage a patch under `id` (replacing what `id` staged), then promote until
  nothing staged can. The empty id is no patch's: it is refused (`"bad-id"`),
  and nothing is staged.
  """
  @spec stage(t(), id, [entry]) :: {t(), verdict}
  def stage(%__MODULE__{} = u, @change, _entries) do
    {u, {:staged, [%{name: nil, code: "bad-id", message: @no_id}]}}
  end

  def stage(%__MODULE__{} = u, id, entries) when is_binary(id) do
    u = put(u, id, entries)
    {promoted, u} = settle(u, id, &find/3)

    {verdict, u} =
      if id in promoted do
        {{:promoted, promoted}, u}
      else
        {reasons, u} = reasons_of(u, id)
        {{:staged, reasons}, u}
      end

    {collect(u, false), verdict}
  end

  @doc """
  Drop a staged patch; whether `id` staged one. Nothing can promote because
  of it: every set without it could not promote before either.
  """
  @spec unstage(t(), id) :: {t(), boolean()}
  def unstage(%__MODULE__{} = u, id) do
    case take(u, id) do
      {nil, _} -> {u, false}
      {_, u} -> {collect(u, false), true}
    end
  end

  @doc """
  Why a staged patch cannot promote on its own (`[]` for an id nothing is
  staged under). Which declarations break is checked through the database,
  only for those that could; their errors are those checks', each unbound
  name's message worded again from the whole table (what a fresh check
  over it says).
  """
  @spec reasons(t(), id) :: [reason]
  def reasons(%__MODULE__{} = u, id), do: u |> reasons_of(id) |> elem(0)

  @doc """
  The universe storage keeps (`durable/1`): `commits` (oldest first),
  `staged` patches in staging order, and `decls`, the declaration of each
  CID by CID, which must hold every one the commits replay to and every one
  staged. Committed code is checked again, as one patch of any size; then
  each staged patch is staged again, in order, through `stage/3`, so its
  reasons are worked out afresh.

  `{:degraded, u, reasons}`: committed code no longer typechecks; `u` is
  restored degraded (see "Degraded"), `reasons` why (also `degraded/1`).
  Should a staged patch repair it while restaging, the result is `{:ok, u}`.

  `{:error, reasons}` says why storage cannot be restored at all: a CID with
  no declaration (`name: nil`, the message naming the CID), a declaration
  that is not the CID or the name it is given for (`Kinoko.Lang.Cid.of/1`
  is worked out again), all `"restore"`.
  """
  @spec restore([round], [{id, [{String.t(), String.t() | :gone}]}], %{String.t() => Ast.decl()}) ::
          {:ok, t()} | {:degraded, t(), [reason]} | {:error, [reason]}
  def restore(commits, staged, decls) do
    code =
      commits |> replay() |> Enum.sort() |> Enum.map(fn {name, cid} -> {:live, name, cid} end)

    patches =
      for {id, entries} <- staged do
        {id,
         Enum.map(entries, fn
           {name, :gone} -> {:gone, name}
           {name, cid} -> {:live, name, cid}
         end)}
      end

    entries = code ++ Enum.flat_map(patches, &elem(&1, 1))

    case entries |> Enum.flat_map(&unheld(&1, decls)) |> Enum.uniq() do
      [] -> restage(commits, patches, decls)
      errors -> {:error, errors}
    end
  end

  # Why `decls` does not hold the declaration an entry names: `[]`, or one reason.
  defp unheld({:gone, _}, _decls), do: []

  defp unheld({:live, name, cid}, decls) do
    case Map.fetch(decls, cid) do
      :error ->
        [restore_error(nil, "#{name} is #{cid}, and no declaration is given for it")]

      {:ok, decl} ->
        cond do
          Cid.of(decl) != cid ->
            [restore_error(name, "the declaration given for #{cid} is #{Cid.of(decl)}")]

          Ast.name(decl) != name ->
            [restore_error(name, "the declaration of #{cid} defines #{Ast.name(decl)}")]

          true ->
            []
        end
    end
  end

  defp restage(commits, patches, decls) do
    code = for {_, cid} <- Enum.sort(replay(commits)), do: {:live, Map.fetch!(decls, cid)}
    {u, verdict} = if code == [], do: {new(), nil}, else: stage(new(), @restore, code)

    u =
      case verdict do
        {:staged, reasons} -> %{commit_as_stored(u, @restore) | degraded: reasons}
        _ -> u
      end

    u = %{u | history: Enum.reverse(commits)}

    u =
      Enum.reduce(patches, u, fn {id, entries}, u ->
        entries =
          Enum.map(entries, fn
            {:live, _, cid} -> {:live, Map.fetch!(decls, cid)}
            gone -> gone
          end)

        u |> stage(id, entries) |> elem(0)
      end)

    case u.degraded do
      nil -> {:ok, u}
      reasons -> {:degraded, u, reasons}
    end
  end

  # Commit the staged patch `id` as it is, typecheck or not: each
  # declaration as checked in the image the patch makes, unchecked
  # (`typed: nil`) where that check fails. Only for restoring storage whose
  # code no longer typechecks; no round is kept.
  defp commit_as_stored(u, id) do
    ctx = Db.ctx([id])
    patch = Map.fetch!(u.staged, id)

    {checked, u} =
      Enum.map_reduce(patch, u, fn {:live, name, cid, decl}, u ->
        {outcome, salsa} = Db.checked(u.salsa, ctx, cid, decl)
        {{name, cid, decl, outcome}, %{u | salsa: salsa}}
      end)

    {_, u} = take(u, id)

    Enum.reduce(checked, u, fn {name, cid, decl, outcome}, u ->
      {sig, salsa} = Db.signature(u.salsa, cid)

      %{
        u
        | sigs: Map.put(u.sigs, name, sig),
          salsa: commit(salsa, name, cid),
          committed:
            Map.put(u.committed, name, %{
              cid: cid,
              decl: decl,
              typed: outcome.typed,
              deps: outcome.deps
            })
      }
    end)
  end

  # What to promote: the search's pick, or, while degraded, the patch
  # staged as `root` if the whole image typechecks with it.
  defp find(%__MODULE__{degraded: nil} = u, root, changed), do: Search.search(u, root, changed)
  defp find(u, root, _changed), do: repair(u, root)

  # `{{[id], checks}, u}` when every committed declaration, with the patch
  # `id` applied over them, typechecks (checks of all of them); else `{nil, u}`.
  defp repair(u, id) do
    patch = Map.get(u.staged, id)

    if patch == nil or twice(patch) != [] do
      {nil, u}
    else
      ctx = Db.ctx([id])
      own = Map.new(patch, &{entry_name(&1), &1})

      image =
        (Map.keys(u.committed) ++ Map.keys(own))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          case own do
            %{^name => {:live, _, _, _} = e} -> [e]
            %{^name => {:gone, _}} -> []
            _ -> [declared(name, u.committed[name])]
          end
        end)

      Enum.reduce_while(image, {%{}, u}, fn {:live, name, cid, decl}, {checks, u} ->
        {outcome, salsa} = Db.checked(u.salsa, ctx, cid, decl)
        u = %{u | salsa: salsa}

        if outcome.typed == nil,
          do: {:halt, {nil, u}},
          else: {:cont, {Map.put(checks, name, outcome), u}}
      end)
      |> case do
        {nil, u} -> {nil, u}
        {checks, u} -> {{MapSet.new([id]), checks}, u}
      end
    end
  end

  defp restore_error(name, message), do: %{name: name, code: "restore", message: message}

  # ---------- staging (@doc false: the naive reference in test/support uses these) ----------

  @doc false
  # Entries as the universe keeps them: each live one with its CID, no positions.
  def internal({:live, decl}) do
    decl = Ast.without_positions(decl)
    {:live, Ast.name(decl), Cid.of(decl), decl}
  end

  def internal({:gone, name}) when is_binary(name), do: {:gone, name}

  @doc false
  def entry_name({:live, name, _, _}), do: name
  def entry_name({:gone, name}), do: name

  @doc false
  # Stage `entries` under `id`, replacing what `id` held, in the database too.
  def put(u, id, entries) do
    {_, u} = take(u, id)
    patch = Enum.map(entries, &internal/1)
    layer = {:patch, id}

    u =
      Enum.reduce(patch, u, fn
        {:live, name, cid, decl}, u ->
          salsa =
            if MapSet.member?(u.cas, cid),
              do: u.salsa,
              else: Salsa.set(u.salsa, :cas, {:decl, cid}, {cid, decl})

          %{u | salsa: Salsa.set(salsa, layer, {:name, name}, cid), cas: MapSet.put(u.cas, cid)}

        {:gone, name}, u ->
          %{u | salsa: Salsa.set(u.salsa, layer, {:name, name}, :tombstone)}
      end)

    %{
      u
      | staged: Map.put(u.staged, id, patch),
        given: Map.put(u.given, id, entries),
        order: [id | u.order]
    }
  end

  # Take what `id` stages out of staging, and out of the database.
  defp take(u, id) do
    case Map.pop(u.staged, id) do
      {nil, _} ->
        {nil, u}

      {patch, staged} ->
        salsa =
          Enum.reduce(patch, u.salsa, &Salsa.unset(&2, {:patch, id}, {:name, entry_name(&1)}))

        {patch,
         %{
           u
           | staged: staged,
             given: Map.delete(u.given, id),
             order: List.delete(u.order, id),
             salsa: salsa
         }}
    end
  end

  @doc false
  # Promote what `find` picks, round after round, each round one history
  # entry; the first root is the staged patch, every later one the names the
  # last round promoted. `find.(u, root, changed)` gives `{nil | {ids, checks}, u}`.
  # Returns the patches that promoted, in order.
  def settle(u, id, find), do: settle(u, id, MapSet.new(), [], find)

  defp settle(u, root, changed, promoted, find) do
    case find.(u, root, changed) do
      {nil, u} ->
        {promoted, u}

      {{ids, checks}, u} ->
        ids = Enum.sort(ids)

        # Patches that promote together touch distinct names, or are the
        # same patch under two ids.
        {applied, u} =
          Enum.reduce(ids, {%{}, u}, fn i, {applied, u} ->
            {patch, u} = take(u, i)
            {Enum.reduce(patch, applied, &Map.put(&2, entry_name(&1), &1)), u}
          end)

        applied = applied |> Map.values() |> Enum.sort_by(&entry_name/1)
        {u, checks} = Enum.reduce(applied, {u, checks}, &apply_entry/2)

        # Committed declarations the trial checked again now follow the
        # signatures they were checked against.
        committed =
          Enum.reduce(checks, u.committed, fn {name, outcome}, committed ->
            case committed do
              %{^name => c} ->
                Map.put(committed, name, %{c | typed: typed!(outcome), deps: outcome.deps})

              _ ->
                committed
            end
          end)

        round = %{ids: ids, entries: Enum.map(applied, &applied/1)}
        changed = MapSet.new(applied, &entry_name/1)

        # A round promoted while degraded checked the whole image: the
        # universe is sound again, and every committed or staged name counts
        # as changed, so every patch the degradation held back is tried.
        changed =
          if u.degraded do
            staged = for {_, patch} <- u.staged, e <- patch, do: entry_name(e)
            MapSet.union(changed, MapSet.new(Map.keys(committed) ++ staged))
          else
            changed
          end

        u = %{u | committed: committed, history: [round | u.history], degraded: nil}
        settle(u, @change, changed, promoted ++ ids, find)
    end
  end

  defp applied({:live, name, cid, _}), do: {:live, name, cid}
  defp applied({:gone, name}), do: {:gone, name}

  defp apply_entry({:live, name, cid, decl}, {u, checks}) do
    {outcome, checks} = Map.pop(checks, name)
    outcome || raise "#{name}: a promoted declaration was never checked"
    {sig, salsa} = Db.signature(u.salsa, cid)

    u = %{
      u
      | sigs: Map.put(u.sigs, name, sig),
        salsa: commit(salsa, name, cid),
        committed:
          Map.put(u.committed, name, %{
            cid: cid,
            decl: decl,
            typed: typed!(outcome),
            deps: outcome.deps
          })
    }

    {u, checks}
  end

  # Remove `name` from committed code (the stdlib's signature of it, if
  # any, is `signatures/1`'s).
  defp apply_entry({:gone, name}, {u, checks}) do
    u = %{
      u
      | committed: Map.delete(u.committed, name),
        salsa:
          u.salsa
          |> Salsa.unset(:committed, {:name, name})
          |> Salsa.unset(:committed, {:committed, name}),
        sigs: Map.delete(u.sigs, name)
    }

    {u, checks}
  end

  # `name` committed as `cid` in the database: what every context reads
  # under it unless a patch says otherwise (`{:name, _}`), and what the
  # evolution rule compares a patch with (`{:committed, _}`, which no patch
  # holds).
  defp commit(salsa, name, cid) do
    salsa
    |> Salsa.set(:committed, {:name, name}, cid)
    |> Salsa.set(:committed, {:committed, name}, cid)
  end

  defp typed!(%{typed: nil}), do: raise("a promoted declaration typechecks")
  defp typed!(%{typed: typed}), do: typed

  # ---------- reasons ----------

  defp reasons_of(u, id) do
    case Map.fetch(u.staged, id) do
      :error ->
        {[], u}

      {:ok, patch} ->
        case twice(patch) do
          [] -> broken_reasons(u, id, patch)
          twice -> {twice, u}
        end
    end
  end

  defp broken_reasons(u, id, patch) do
    # The patch's declarations, and the committed ones it can break. One
    # defining a stdlib name (refused, for its name) can break whatever
    # consults the stdlib: all committed code.
    touched = MapSet.new(patch, &entry_name/1)
    own = for {:live, _, _, _} = e <- patch, do: e

    # While degraded, the patch must make the whole image typecheck.
    others =
      if defines_stdlib?(patch) or u.degraded != nil,
        do: for({name, c} <- u.committed, name not in touched, do: declared(name, c)),
        else: dependents(u.committed, patch)

    code = Enum.sort_by(own ++ others, &entry_name/1)
    ctx = Db.ctx([id])

    {broken, salsa} =
      Enum.flat_map_reduce(code, u.salsa, fn {:live, name, cid, decl}, salsa ->
        {outcome, salsa} = Db.checked(salsa, ctx, cid, decl)
        {if(outcome.typed == nil, do: [{name, outcome.errors}], else: []), salsa}
      end)

    u = %{u | salsa: salsa}

    if broken == [] do
      {[], u}
    else
      {changes, u} =
        Enum.map_reduce(patch, u, fn
          {:live, name, cid, _}, u ->
            {sig, salsa} = Db.signature(u.salsa, cid)
            {{name, sig}, %{u | salsa: salsa}}

          {:gone, name}, u ->
            {{name, nil}, u}
        end)

      # The whole table, built once for every broken declaration, and only
      # when one of them has an unbound name to word.
      table =
        if Enum.any?(broken, fn {_, errors} -> Enum.any?(errors, & &1.unbound) end),
          do: Hints.table(over(signatures(u), changes))

      reasons =
        Enum.flat_map(broken, fn
          {name, []} ->
            [%{name: name, code: "internal", message: @no_error}]

          {name, errors} ->
            Enum.map(errors, &%{name: name, code: &1.code, message: Hints.reword(table, &1)})
        end)

      {reasons, u}
    end
  end

  @doc false
  # What a patch that touches a name twice says: one reason per name it
  # touches again. `[]` if it touches each once.
  def twice(patch) do
    {reasons, _} =
      Enum.flat_map_reduce(patch, %{}, fn e, first ->
        name = entry_name(e)

        case first do
          %{^name => before} ->
            both = match?({:live, _, _, _}, before) and match?({:live, _, _, _}, e)
            how = if both, do: "defined", else: "named"

            {[%{name: name, code: "duplicate", message: "#{how} twice in this patch"}],
             Map.put(first, name, e)}

          _ ->
            {[], Map.put(first, name, e)}
        end
      end)

    reasons
  end

  @doc false
  # `sigs` with a patch's `changes` applied over them (each name's new
  # signature, or `nil` where it removes the name). A removed name leaves
  # the stdlib's signature of it, if the stdlib has one.
  def over(sigs, changes) do
    Enum.reduce(changes, sigs, fn {name, sig}, sigs ->
      case sig || Stdlib.signature(name) do
        nil -> Map.delete(sigs, name)
        sig -> Map.put(sigs, name, sig)
      end
    end)
  end

  @doc false
  # Whether `patch` defines a name the language provides (`Stdlib.provided?/1`):
  # no check's dependencies hold one, so such a patch can break any of them.
  def defines_stdlib?(patch),
    do: Enum.any?(patch, &(match?({:live, _, _, _}, &1) and Stdlib.provided?(entry_name(&1))))

  @doc false
  # A committed declaration as a live entry.
  def declared(name, c), do: {:live, name, c.cid, c.decl}

  @doc false
  # The committed declarations whose check `patch` can change, but for one
  # that defines a stdlib name: those that consult a name it touches, and
  # that it does not touch itself. In name order.
  def dependents(committed, patch) do
    touched = MapSet.new(patch, &entry_name/1)

    for {name, c} <- Enum.sort(committed),
        name not in touched,
        Enum.any?(c.deps, &MapSet.member?(touched, &1)),
        do: declared(name, c)
  end

  # ---------- forgetting ----------

  @doc false
  # Once the database holds memos for more than twice as many queries as
  # were kept last time (and a few), or `now`, drop every memo of a
  # declaration neither committed nor staged code holds, or that read one,
  # and of a name neither defines nor the stdlib has; then the CAS entries
  # of those declarations, and every version that read what no memo gives
  # any more (`Salsa.trim/1`). So the memos stay within a few times what the
  # code needs, and dropping them costs a constant per memo made.
  def collect(u, now) do
    if not now and Salsa.queries(u.salsa) <= 2 * u.kept + 64 do
      u
    else
      live = for {_, patch} <- u.staged, {:live, _, cid, _} <- patch, do: cid
      cids = MapSet.new(live ++ Enum.map(u.committed, fn {_, c} -> c.cid end))
      staged_names = for {_, patch} <- u.staged, e <- patch, do: entry_name(e)
      names = MapSet.new(staged_names ++ Map.keys(u.committed))

      salsa =
        u.salsa
        |> Salsa.retain(fn
          {:signature, cid} -> MapSet.member?(cids, cid)
          {:check, cid} -> MapSet.member?(cids, cid)
          {:evolution, cid} -> MapSet.member?(cids, cid)
          {_, name} -> MapSet.member?(names, name) or Stdlib.signature(name) != nil
        end)
        |> Salsa.retain_reads(fn
          {cid, _decl} -> MapSet.member?(cids, cid)
          cid -> MapSet.member?(cids, cid)
        end)

      {dead, cas} = Enum.split_with(u.cas, &(not MapSet.member?(cids, &1)))
      salsa = dead |> Enum.reduce(salsa, &Salsa.unset(&2, :cas, {:decl, &1})) |> Salsa.trim()
      %{u | salsa: salsa, cas: MapSet.new(cas), kept: Salsa.queries(salsa)}
    end
  end
end
