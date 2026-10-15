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
  table (`sigs`: the stdlib's and committed code's, the patch over them),
  built once per staging that needs it (`Kinoko.Lang.Types.Hints.reword/2`).
  So a failing declaration is checked once, through the database, never
  again for its messages.

  A universe is a value; every operation returns the new one.

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
            sigs: %{},
            salsa: nil,
            cas: MapSet.new(),
            kept: 0

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
  def new, do: %__MODULE__{sigs: Stdlib.signatures(), salsa: Salsa.new(Db)}

  @doc "Every promoted round, oldest first. Only ever appended to."
  @spec history(t()) :: [round]
  def history(%__MODULE__{history: history}), do: Enum.reverse(history)

  @doc "Committed code: `%{name => %{cid, decl, typed, deps}}`, each as checked against it."
  @spec committed(t()) :: %{String.t() => map()}
  def committed(%__MODULE__{committed: committed}), do: committed

  @doc "What each staged patch holds, as it was staged."
  @spec staged(t()) :: %{id => [entry]}
  def staged(%__MODULE__{given: given}), do: given

  @doc "The stdlib's signatures and committed code's."
  @spec signatures(t()) :: map()
  def signatures(%__MODULE__{sigs: sigs}), do: sigs

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
    {promoted, u} = settle(u, id, &Search.search/3)

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

  `{:error, reasons}` says why not: a CID with no declaration (`name: nil`,
  the message naming the CID), a declaration that is not the CID or the
  name it is given for (`Kinoko.Lang.Cid.of/1` is worked out again), all
  `"restore"`; or the reasons committed code does not typecheck.
  """
  @spec restore([round], [{id, [{String.t(), String.t() | :gone}]}], %{String.t() => Ast.decl()}) ::
          {:ok, t()} | {:error, [reason]}
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

    case verdict do
      {:staged, reasons} ->
        {:error, reasons}

      _ ->
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

        {:ok, u}
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
        u = %{u | committed: committed, history: [round | u.history]}
        changed = MapSet.new(applied, &entry_name/1)
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
        salsa: Salsa.set(salsa, :committed, {:name, name}, cid),
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

  # Remove `name` from committed code: the stdlib's signature of it is what
  # is left, if the stdlib has one.
  defp apply_entry({:gone, name}, {u, checks}) do
    sigs =
      case Stdlib.signature(name) do
        nil -> Map.delete(u.sigs, name)
        sig -> Map.put(u.sigs, name, sig)
      end

    u = %{
      u
      | committed: Map.delete(u.committed, name),
        salsa: Salsa.unset(u.salsa, :committed, {:name, name}),
        sigs: sigs
    }

    {u, checks}
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

    others =
      if defines_stdlib?(patch),
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
          do: Hints.table(over(u.sigs, changes))

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
