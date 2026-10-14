defmodule Kinoko.Exec.Hooks do
  @moduledoc """
  What compiled Yabu code reports outside its pure value tree.

  A false `always(e)` does not stop evaluation (Rust's evaluator records it
  and goes on); the generated code calls `always_failed/1` with the site's
  source (`Kinoko.Lang.Format.expr/1` of `e`). The failure is kept in the
  calling process's dictionary under `#{inspect(:kinoko_exec_always_failures)}`,
  most recent first, and `take_failures/0` hands them back in the order they
  happened, each worded as Rust's test scorer words it:
  `"always failed: <source>"`.

  Every run (`Kinoko.Exec`) happens in its own process, so failures never
  leak from one run to another.
  """

  @key :kinoko_exec_always_failures

  @doc "Records a failed `always` at the site whose source is `source`; Unit."
  @spec always_failed(String.t()) :: {}
  def always_failed(source) when is_binary(source) do
    Process.put(@key, ["always failed: " <> source | Process.get(@key, [])])
    {}
  end

  @doc "The failures recorded in this process, oldest first, and forgets them."
  @spec take_failures() :: [String.t()]
  def take_failures do
    case Process.delete(@key) do
      nil -> []
      failures -> Enum.reverse(failures)
    end
  end
end
