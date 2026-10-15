defmodule Kinoko.Elm.Store do
  @moduledoc """
  Append-only persistence of Elm-style server state snapshots.

  Rows are keyed by `(key, seq)` and never updated; `prune/2` is the only
  delete. State is an opaque binary (maps out, binaries in).
  """

  import Ecto.Query

  alias Kinoko.Repo

  @doc "Appends a snapshot. Raises on failure, including a duplicate `(key, seq)`."
  @spec append(String.t(), non_neg_integer(), pos_integer(), binary()) :: :ok
  def append(key, seq, version, state) when is_binary(state) do
    Repo.insert_all("elm_states", [
      %{key: key, seq: seq, version: version, state: state, inserted_at: DateTime.utc_now()}
    ])

    :ok
  end

  @spec latest(String.t()) ::
          {:ok, %{seq: integer(), version: integer(), state: binary()}} | :none
  def latest(key) do
    query =
      from s in "elm_states",
        where: s.key == ^key,
        order_by: [desc: s.seq],
        limit: 1,
        select: %{seq: s.seq, version: s.version, state: s.state}

    case Repo.one(query) do
      nil -> :none
      row -> {:ok, row}
    end
  end

  @doc "Newest first."
  @spec history(String.t(), pos_integer()) :: [map()]
  def history(key, limit \\ 50) do
    Repo.all(
      from s in "elm_states",
        where: s.key == ^key,
        order_by: [desc: s.seq],
        limit: ^limit,
        select: %{seq: s.seq, version: s.version, state: s.state, inserted_at: s.inserted_at}
    )
  end

  @doc "Deletes all but the newest `keep` rows for `key`; returns rows deleted."
  @spec prune(String.t(), pos_integer()) :: non_neg_integer()
  def prune(key, keep) when is_integer(keep) and keep > 0 do
    case latest(key) do
      :none ->
        0

      {:ok, %{seq: top}} ->
        newest =
          from s in "elm_states",
            where: s.key == ^key,
            order_by: [desc: s.seq],
            limit: ^keep,
            select: s.seq

        cutoff = newest |> Repo.all() |> List.last() || top

        {n, _} = Repo.delete_all(from s in "elm_states", where: s.key == ^key and s.seq < ^cutoff)
        n
    end
  end
end
