defmodule Kinoko.Exec.Hooks do
  @moduledoc """
  What compiled Yabu code reports outside its pure value tree: the
  assertions it evaluated, which a deftest is scored by.

  - A false `always(e)` does not stop evaluation (Rust's evaluator records
    it and goes on). The generated code calls `always_failed/1` with the
    site's source (`Kinoko.Lang.Format.expr/1` of `e`). `take_failures/0`
    hands the failures back in the order they happened, each worded as
    Rust's test scorer words it: `"always failed: <source>"`.
  - A `sometimes(e)` written in a declaration calls `sometimes_held/2` with
    the declaration's name and the site's source each time `e` holds.
    `take_reached/0` hands back the `{decl, source}` sites that held.

  Both live in the calling process's dictionary (under
  `#{inspect(:kinoko_exec_always_failures)}` and
  `#{inspect(:kinoko_exec_sometimes_held)}`). Every run (`Kinoko.Exec`)
  happens in its own process, so nothing leaks from one run to another.
  """

  @failures :kinoko_exec_always_failures
  @held :kinoko_exec_sometimes_held

  @doc "Records a failed `always` at the site whose source is `source`; Unit."
  @spec always_failed(String.t()) :: {}
  def always_failed(source) when is_binary(source) do
    Process.put(@failures, ["always failed: " <> source | Process.get(@failures, [])])
    {}
  end

  @doc "The failures recorded in this process, oldest first, and forgets them."
  @spec take_failures() :: [String.t()]
  def take_failures do
    case Process.delete(@failures) do
      nil -> []
      failures -> Enum.reverse(failures)
    end
  end

  @doc "Records that the `sometimes` site `source` of declaration `decl` held; Unit."
  @spec sometimes_held(String.t(), String.t()) :: {}
  def sometimes_held(decl, source) when is_binary(decl) and is_binary(source) do
    held = Process.get(@held, MapSet.new())
    # A site holds once for good: put only what is new.
    unless MapSet.member?(held, {decl, source}),
      do: Process.put(@held, MapSet.put(held, {decl, source}))

    {}
  end

  @doc "The `{decl, source}` sites that held in this process, and forgets them."
  @spec take_reached() :: MapSet.t({String.t(), String.t()})
  def take_reached, do: Process.delete(@held) || MapSet.new()
end
