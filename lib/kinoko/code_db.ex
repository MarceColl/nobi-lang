defmodule Kinoko.CodeDb do
  @moduledoc """
  The process that keeps one universe alive: a `Kinoko.PersistentElmGenServer`
  under `Kinoko.Elm.Supervisor`, keyed `"universe:" <> name` (`key/1`) and
  started with `Kinoko.PersistentElmGenServer.start/3`. Its state is
  `%{u: u, hash: hash}`: a `Kinoko.Lang` universe and the hash of its
  committed image (`Kinoko.Lang.image_hash/1`), kept so a caller can find an
  image already loaded without copying the committed code out
  (`:image_key`). The hash is worked out again only when a stage promotes.

  **Internal.** Only `Kinoko.Universe` starts it or talks to it.

  `update/2` is pure and only applies `Kinoko.Lang`. It serializes check,
  promote and persist; parsing, CAS writes and evaluation happen in callers.

  ## Messages (`{:call, from, request}`, replied with `Effect.reply`)

    * `{:stage, id, entries}` → `{:promoted, [id]} | {:staged, [reason]}`
      (`Kinoko.Lang.stage_entries/3`; the entries' text is already in the CAS)
    * `{:unstage, id}` → `:ok | :not_found | {:error, reason}`
    * `:symbols` → `[%{symbol, cid, signature}]`
    * `{:read, symbol}` → `{:ok, text} | :error`
    * `:staged` → `[%{id, source, removes, reasons}]`, in staging order
    * `:history` → `[commit]`, oldest first
    * `:definers` → `%{symbol => [id]}`: the staged patches defining each
      symbol, in staging order
    * `:health` → `:ok | {:degraded, [reason]}` (`Kinoko.Lang.health/1`)
    * `:image_key` → `{:ok, hash, signatures}`: the committed image's hash
      and the signatures to check an expression against; cheap
    * `:snapshot` → `{:ok, Kinoko.Lang.snapshot/1}`: the whole committed code
    * anything else → `{:error, :unknown_request}`

  While the universe is degraded, `:image_key` and `:snapshot` answer
  `{:degraded, reasons}`: its committed code cannot run.

  ## Storage

  `durable/1` is `Kinoko.Lang.durable/1`: commits and staged patches as names
  and CIDs, never text. `decode/1` fetches the declarations by CID from
  `Kinoko.Cas`, parses them and rebuilds the universe with
  `Kinoko.Lang.restore/3`, which checks the code again.

    * Committed code that no longer typechecks (the checker changed under
      it) boots **degraded** (logged), never refused: see `Kinoko.Lang.health/1`.
    * A CID missing from the CAS, or a text that does not parse to one
      declaration, is corrupt storage: it raises naming the CID, so the boot
      refuses. (A restart by the supervisor that refuses is dropped, not
      retried: see `Kinoko.PersistentElmGenServer`.)

  The salsa memo is never stored; it refills lazily.
  """

  use Kinoko.PersistentElmGenServer

  require Logger

  alias Kinoko.{Cas, Lang}
  alias Kinoko.Elm.Effect, as: Fx

  @doc "The `Kinoko.Elm.Registry` key of universe `name`'s CodeDb."
  @spec key(String.t()) :: String.t()
  def key(name), do: "universe:" <> name

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

  def update({:call, from, request}, %{u: u} = s) do
    {s, reply} =
      case handle(request, u) do
        {u, {:promoted, _} = reply} -> {state(u), reply}
        {u, reply} -> {%{s | u: u}, reply}
      end

    {s, Fx.reply(from, reply)}
  end

  # A stray message (a cast, an info) changes nothing.
  def update(_msg, s), do: {s, Fx.none()}

  defp handle({:stage, id, entries}, u), do: Lang.stage_entries(u, id, entries)

  defp handle({:unstage, id}, u) do
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
  def encode(durable), do: :erlang.term_to_binary(durable, compressed: 6)

  @impl true
  def decode(binary) do
    %{commits: commits, staged: staged} = :erlang.binary_to_term(binary, [:safe])
    wanted = referenced(commits, staged)
    texts = Cas.get(Map.keys(wanted))

    decls =
      Map.new(wanted, fn {cid, symbol} ->
        case Map.fetch(texts, cid) do
          {:ok, text} -> {cid, parse!(cid, symbol, text)}
          :error -> raise "declaration #{cid} (#{symbol}) is missing from the CAS"
        end
      end)

    case Lang.restore(commits, staged, decls) do
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
