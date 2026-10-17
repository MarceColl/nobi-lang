defmodule Kinoko.Build do
  @moduledoc """
  What this build is: the `mix.exs` version and the commit it was compiled
  from (see `Kinoko.Build.Commit`).
  """

  @version Mix.Project.config()[:version]
  @commit Kinoko.Build.Commit.read()

  # Recompile when the source moved on, so the stamped commit stays true.
  @doc false
  def __mix_recompile__?, do: Kinoko.Build.Commit.read() != @commit

  @doc "The application version, from `mix.exs`."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The commit this build was compiled from (short id), or `\"unknown\"`."
  @spec commit() :: String.t()
  def commit, do: @commit
end
