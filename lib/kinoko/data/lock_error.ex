defmodule Kinoko.Data.LockError do
  @moduledoc """
  Raised by `Kinoko.Data.Lock.with_lock/2` when a deployment's write lock
  cannot be had: `reason` is `:busy` (another writer held it past the
  file's `busy_timeout`) or `:down` (the file's opener is gone).
  `Kinoko.Data` turns it into its `"unavailable"` error.
  """

  defexception [:reason]

  @impl true
  def message(%{reason: :busy}), do: "the write lock was held past busy_timeout"
  def message(%{reason: :down}), do: "the store's opener is gone"
end
