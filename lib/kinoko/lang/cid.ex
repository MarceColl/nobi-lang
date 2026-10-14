defmodule Kinoko.Lang.Cid do
  @moduledoc "Content identifiers: sha256 over the version tag and a declaration's canonical text."

  alias Kinoko.Lang.Format

  @version "yabu/1"

  @spec version() :: String.t()
  def version, do: @version

  @doc "64 lowercase hex characters; layout and line endings do not matter, content does."
  @spec of(Kinoko.Lang.Ast.decl()) :: String.t()
  def of(decl) do
    :sha256 |> :crypto.hash([@version, "\n", Format.decl(decl)]) |> Base.encode16(case: :lower)
  end
end
