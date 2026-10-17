defmodule Nobi.Cas do
  @moduledoc """
  Content-addressed store of declaration text, keyed by CID.

  Append-only: inserts use `on_conflict: :nothing`, so putting the same CID
  twice (even concurrently) is harmless. There is no process; these are plain
  functions over `Nobi.Repo`, safe from any process.
  """

  import Ecto.Query

  alias Nobi.Repo

  # SQLite allows 32_766 bound parameters; each row uses 3 (cid, text, inserted_at).
  @chunk 10_000

  @spec put([{String.t(), String.t()}]) :: :ok
  def put([]), do: :ok

  def put(pairs) when is_list(pairs) do
    now = DateTime.utc_now()

    pairs
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      rows = for {cid, text} <- chunk, do: %{cid: cid, text: text, inserted_at: now}
      Repo.insert_all("declarations", rows, on_conflict: :nothing, conflict_target: :cid)
    end)

    :ok
  end

  @doc "Returns `%{cid => text}`; CIDs that do not exist are absent."
  @spec get([String.t()]) :: %{String.t() => String.t()}
  def get([]), do: %{}

  def get(cids) when is_list(cids) do
    cids
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(from d in "declarations", where: d.cid in ^chunk, select: {d.cid, d.text})
    end)
    |> Map.new()
  end
end
