defmodule Nobi.Universe.Current do
  @moduledoc """
  A universe's committed image as of one moment, made by
  `Nobi.Universe.current/1`: its hash and the signatures to check
  against. Opaque: pass it where `Nobi.Universe` takes a universe
  (`call/4`, `apply/4`, `eval/3`, `test/3`, `routes/1`) to run several
  calls on the same image with a single CodeDb round trip. Short-lived:
  unlike `Nobi.Universe.At` it names no commit, so an image that is no
  longer loaded is replaced by the universe's current one.
  """

  @enforce_keys [:universe, :hash, :signatures]
  defstruct @enforce_keys

  @type t :: %__MODULE__{universe: String.t(), hash: String.t(), signatures: map()}
end
