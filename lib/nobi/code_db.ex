defmodule Nobi.CodeDb do
  @moduledoc """
  The process that keeps one universe alive: a `Nobi.PersistentElmGenServer`
  under `Nobi.Elm.Supervisor`, keyed `"universe:" <> name` (`key/1`) and
  started with `Nobi.PersistentElmGenServer.start/3`. Its state is
  `%{u: u, hash: hash}`: a `Nobi.Lang` universe and the hash of its
  committed image (`Nobi.Lang.image_hash/1`), kept so a caller can find an
  image already loaded without copying the committed code out
  (`:image_key`). The hash is worked out again only when a stage promotes.

  **Internal.** Only `Nobi.Universe` starts it or talks to it.

  `update/2` is pure and only applies `Nobi.Lang`. It serializes check,
  promote and persist; parsing, CAS writes and evaluation happen in callers.

  ## Messages (`{:call, from, request}`, replied with `Effect.reply`)

    * `{:stage, universe, id, entries}` → `{:promoted, [id]} | {:staged, [reason]}`
      (`Nobi.Lang.stage_entries/3`; the entries' text is already in the CAS)
    * `{:unstage, universe, id}` → `:ok | :not_found | {:error, reason}`
      (never promotes: `Nobi.Lang.unstage/2` leaves history as it is)
    * `:symbols` → `[%{symbol, cid, signature}]`
    * `{:read, symbol}` → `{:ok, text} | :error`
    * `:staged` → `[%{id, source, defines, removes, reasons}]`, in staging order
    * `:history` → `[commit]`, oldest first
    * `:definers` → `%{symbol => [id]}`: the staged patches defining each
      symbol, in staging order
    * `:health` → `:ok | {:degraded, [reason]}` (`Nobi.Lang.health/1`)
    * `:image_key` → `{:ok, hash, signatures}`: the committed image's hash
      and the signatures to check an expression against; cheap
    * `:snapshot` → `{:ok, Nobi.Lang.snapshot/1}`: the whole committed code
    * anything else → `{:error, :unknown_request}`

  While the universe is degraded, `:image_key` and `:snapshot` answer
  `{:degraded, reasons}`: its committed code cannot run.

  ## Commits are broadcast

  A write (`:stage` or `:unstage`) after which the history is longer
  returns, besides the reply, an `Effect.broadcast/3` of
  `{:committed, universe, %{commit: n, image_hash: hash}}` on
  `Nobi.PubSub`, topic `"universe:" <> universe` (`topic/1`): `n` the new
  history's length (1-based, the newest commit) and `hash` the new committed
  image's. Effects run after the step's state is stored, so a subscriber
  never hears of a commit that a restart could lose. A stage that promotes
  nothing broadcasts nothing, and neither does an unstage (it never
  promotes; checking the history keeps that an invariant of Lang's, not
  an assumption here). The universe's
  name travels in the write (the stored state does not hold it).

  ## Storage

  `durable/1` is `Nobi.Lang.durable/1`: commits and staged patches as names
  and CIDs, never text.

  `encode/1` writes it with **no atom anywhere** (version 2): strings, lists
  and maps with string keys only, an entry `["live", symbol, cid]` or
  `["gone", symbol]`. `binary_to_term/2` with `:safe` refuses atoms the node
  does not know yet, and in dev modules load lazily, so a fresh VM booting a
  universe may not have loaded `Nobi.Lang` (whose atoms the durable shape
  uses) when the CodeDb decodes. An atom-free binary decodes on any node.
  Version 1 stored the durable map itself (atoms); `stored/1` still reads
  it, its atoms being literals of this module (so known once it runs), and
  `migrate/2` has nothing left to do: the first step stores it again as
  version 2.

  `decode/1` fetches the declarations by CID from
  `Nobi.Cas`, parses them and rebuilds the universe with
  `Nobi.Lang.restore/3`, which checks the code again.

    * Committed code that no longer typechecks (the checker changed under
      it) boots **degraded** (logged), never refused: see `Nobi.Lang.health/1`.
    * A CID missing from the CAS, or a text that does not parse to one
      declaration, is corrupt storage: it raises naming the CID, so the boot
      refuses. (A restart by the supervisor that refuses is dropped, not
      retried: see `Nobi.PersistentElmGenServer`.)

  The salsa memo is never stored; it refills lazily.
  """

  use Nobi.PersistentElmGenServer

  require Logger

  alias Nobi.{Cas, Lang}
  alias Nobi.Elm.Effect, as: Fx

  @doc "The `Nobi.Elm.Registry` key of universe `name`'s CodeDb."
  @spec key(String.t()) :: String.t()
  def key(name), do: "universe:" <> name

  @doc "The `Nobi.PubSub` topic universe `name`'s commits are broadcast on."
  @spec topic(String.t()) :: String.t()
  def topic(name), do: "universe:" <> name

  @impl true
  def init(_args), do: {state(Lang.new()), Fx.none()}

  defp state(u), do: %{u: u, hash: Lang.image_hash(u)}

  @impl true
  # The cached hash: no committed code is walked or copied.
  def update({:call, from, :image_key}, %{u: u, hash: hash} = s) do
    reply =
      case Lang.health(u) do
        :ok -> {:ok, hash, Lang.signatures(u)}
        degraded -> degraded
      end

    {s, Fx.reply(from, reply)}
  end

  def update({:call, from, {:stage, universe, _id, _entries} = request}, s),
    do: write(from, universe, request, s)

  def update({:call, from, {:unstage, universe, _id} = request}, s),
    do: write(from, universe, request, s)

  def update({:call, from, request}, %{u: u} = s) do
    {u, reply} = handle(request, u)
    {%{s | u: u}, Fx.reply(from, reply)}
  end

  # A stray message (a cast, an info) changes nothing.
  def update(_msg, s), do: {s, Fx.none()}

  # The hash is worked out again, and the commit broadcast, only when the
  # write promoted (the history grew; an unstage never does).
  defp write(from, universe, request, %{u: u} = s) do
    commits = length(Lang.history(u))
    {u, reply} = handle(request, u)

    case length(Lang.history(u)) do
      ^commits ->
        {%{s | u: u}, Fx.reply(from, reply)}

      n ->
        s = state(u)
        committed = {:committed, universe, %{commit: n, image_hash: s.hash}}
        {s, [Fx.reply(from, reply), Fx.broadcast(Nobi.PubSub, topic(universe), committed)]}
    end
  end

  defp handle({:stage, _universe, id, entries}, u), do: Lang.stage_entries(u, id, entries)

  defp handle({:unstage, _universe, id}, u) do
    case Lang.unstage(u, id) do
      {u, true} -> {u, :ok}
      {u, false} -> {u, :not_found}
      {u, {:error, _} = error} -> {u, error}
    end
  end

  defp handle(:symbols, u) do
    {u, for(s <- Lang.symbols(u), do: %{symbol: s.name, cid: s.cid, signature: s.signature})}
  end

  defp handle({:read, symbol}, u), do: {u, Lang.read(u, symbol)}

  defp handle(:staged, u) do
    staged = Lang.staged(u)

    {u,
     for {id, _} <- Lang.durable(u).staged do
       Map.put(staged[id], :id, id)
     end}
  end

  defp handle(:history, u), do: {u, Lang.history(u)}

  defp handle(:definers, u) do
    definers =
      for {id, entries} <- Lang.durable(u).staged,
          {symbol, cid} when is_binary(cid) <- entries,
          reduce: %{} do
        acc -> Map.update(acc, symbol, [id], &(&1 ++ [id]))
      end

    {u, definers}
  end

  defp handle(:health, u), do: {u, Lang.health(u)}

  defp handle(:snapshot, u) do
    case Lang.health(u) do
      :ok -> {u, {:ok, Lang.snapshot(u)}}
      degraded -> {u, degraded}
    end
  end

  defp handle(_request, u), do: {u, {:error, :unknown_request}}

  @impl true
  def durable(%{u: u}), do: Lang.durable(u)

  @impl true
  def version, do: 2

  # `decode/1` already reads a version-1 binary into the current state
  # (see "Storage"), so there is nothing left to migrate.
  @impl true
  def migrate(state, 1), do: state

  @impl true
  def encode(%{commits: commits, staged: staged}) do
    :erlang.term_to_binary(
      %{
        "commits" =>
          for(%{ids: ids, entries: entries} <- commits, do: [ids, Enum.map(entries, &applied/1)]),
        "staged" => for({id, entries} <- staged, do: [id, Enum.map(entries, &staged_entry/1)])
      },
      compressed: 6
    )
  end

  defp applied({:live, symbol, cid}), do: ["live", symbol, cid]
  defp applied({:gone, symbol}), do: ["gone", symbol]

  defp staged_entry({symbol, :gone}), do: ["gone", symbol]
  defp staged_entry({symbol, cid}), do: ["live", symbol, cid]

  # Every atom a version-1 binary holds. Literal atoms exist once this
  # module is loaded, so `binary_to_term/2` with `:safe` reads such a
  # binary on a node that has not loaded `Nobi.Lang` yet.
  @v1_atoms [:commits, :staged, :ids, :entries, :live, :gone]

  @doc """
  The `Nobi.Lang.durable/1` a binary stored by this module holds, read
  without the CAS. Reads both encodings: version 2 (`encode/1`, no atoms)
  and version 1 (`term_to_binary` of the durable map itself).
  """
  @spec stored(binary()) :: %{commits: [map()], staged: [{String.t(), [tuple()]}]}
  def stored(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{"commits" => commits, "staged" => staged} ->
        %{
          commits:
            for(
              [ids, entries] <- commits,
              do: %{ids: ids, entries: Enum.map(entries, &from_applied/1)}
            ),
          staged: for([id, entries] <- staged, do: {id, Enum.map(entries, &from_staged_entry/1)})
        }

      %{commits: _, staged: _} = v1 ->
        true = Enum.all?(@v1_atoms, &is_atom/1)
        v1
    end
  end

  defp from_applied(["live", symbol, cid]), do: {:live, symbol, cid}
  defp from_applied(["gone", symbol]), do: {:gone, symbol}

  defp from_staged_entry(["live", symbol, cid]), do: {symbol, cid}
  defp from_staged_entry(["gone", symbol]), do: {symbol, :gone}

  @impl true
  def decode(binary) do
    %{commits: commits, staged: staged} = stored(binary)

    case restore(commits, staged) do
      {:ok, u} ->
        state(u)

      {:degraded, u, reasons} ->
        Logger.warning(
          "a universe boots degraded: its committed code no longer typechecks (" <>
            Enum.map_join(reasons, "; ", &"#{&1.name} [#{&1.code}] #{&1.message}") <> ")"
        )

        state(u)

      {:error, reasons} ->
        raise "the universe does not restore: " <> Enum.map_join(reasons, "; ", & &1.message)
    end
  end

  @doc """
  `Nobi.Lang.restore/3` of `commits` and `staged` (as `durable/1` stores
  them), each declaration fetched by CID from `Nobi.Cas` and parsed. Raises,
  naming the CID, when one is missing from the CAS or its text does not
  parse to one declaration. Pure but for the CAS read: `Nobi.Universe`
  also calls it, in its caller, to rebuild a past commit (`Universe.at/2`).
  """
  @spec restore([map()], [{String.t(), [tuple()]}]) ::
          {:ok, Lang.Universe.t()}
          | {:degraded, Lang.Universe.t(), [Lang.reason()]}
          | {:error, [Lang.reason()]}
  def restore(commits, staged) do
    wanted = referenced(commits, staged)
    texts = Cas.get(Map.keys(wanted))

    decls =
      Map.new(wanted, fn {cid, symbol} ->
        case Map.fetch(texts, cid) do
          {:ok, text} -> {cid, verified!(cid, symbol, text, parse!(cid, symbol, text))}
          :error -> raise "declaration #{cid} (#{symbol}) is missing from the CAS"
        end
      end)

    Lang.restore(commits, staged, decls, verified: true)
  end

  # The stored text must be what its CID was taken of. Its tree is today's
  # parse of it, which may format (so hash) differently once the parser
  # changes (JSX whitespace did): the CID stays the stored one, never
  # worked out again from the tree.
  defp verified!(cid, symbol, text, decl) do
    if Lang.Cid.of_text(text) == cid,
      do: decl,
      else: raise("declaration #{cid} (#{symbol}) in the CAS does not hash to its CID")
  end

  # `%{cid => symbol}` for every CID restore needs: what the commits replay
  # to (superseded history is not needed) and every staged CID.
  defp referenced(commits, staged) do
    committed =
      Enum.reduce(commits, %{}, fn %{entries: entries}, acc ->
        Enum.reduce(entries, acc, fn
          {:live, symbol, cid}, acc -> Map.put(acc, symbol, cid)
          {:gone, symbol}, acc -> Map.delete(acc, symbol)
        end)
      end)

    pending =
      for {_id, entries} <- staged,
          {symbol, cid} when is_binary(cid) <- entries,
          do: {symbol, cid}

    Map.new(Enum.to_list(committed) ++ pending, fn {symbol, cid} -> {cid, symbol} end)
  end

  defp parse!(cid, symbol, text) do
    case Lang.parse(text) do
      {:ok, [decl]} ->
        decl

      {:ok, decls} ->
        raise "declaration #{cid} (#{symbol}) in the CAS holds #{length(decls)} declarations, not one"

      {:error, error} ->
        raise "declaration #{cid} (#{symbol}) in the CAS does not parse: " <>
                Map.get(error, :message, inspect(error))
    end
  end
end
