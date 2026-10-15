defmodule Kinoko.Universe.At do
  @moduledoc """
  A pinned view of a universe: its code as of commit `commit` (1-based,
  into `Kinoko.Universe.history/1`), made by `Kinoko.Universe.at/2`.

  Opaque: pass it where `Kinoko.Universe` takes a universe (`call/4`,
  `apply/4`, `eval/3`, `test/3`, `apps/1`, `routes/1`). It holds the
  image's hash and the signatures to check against, never the committed
  code: the image is found loaded by hash (`Kinoko.Exec.loaded/1`), and
  rebuilt from history should it have been unloaded (only while the
  history still starts with the rounds it was made from: `fingerprint`).
  """

  @enforce_keys [:universe, :commit, :fingerprint, :hash, :signatures]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          universe: String.t(),
          commit: pos_integer(),
          fingerprint: binary(),
          hash: String.t(),
          signatures: map()
        }
end
