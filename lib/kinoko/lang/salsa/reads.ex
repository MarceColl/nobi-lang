defmodule Kinoko.Lang.Salsa.Reads do
  @moduledoc """
  A query's reads while it computes (`Reads` in `salsa.rs`). A compute
  callback receives one, threads it through `Kinoko.Lang.Salsa.input/2` and
  `Kinoko.Lang.Salsa.ask/2`, and returns it with its value. Opaque to the
  callback: only those functions and `Kinoko.Lang.Salsa.env/1` read it.

  - `db` — the database, threaded through every nested query.
  - `ctx` — the context: layers, first layer first.
  - `active` / `nesting` — the queries being computed or verified, and how
    many there are (cycle and depth detection).
  - `reads` — what this computation read, newest first, each with what it
    gave.
  - `height` — the greatest height among the queries read.
  - `failed` — the first error a read met: the computation fails with it,
    whatever the body makes of it.
  """

  @enforce_keys [:db, :ctx]
  defstruct [:db, :ctx, active: MapSet.new(), nesting: 0, reads: [], height: 0, failed: nil]

  @type t :: %__MODULE__{}
end
