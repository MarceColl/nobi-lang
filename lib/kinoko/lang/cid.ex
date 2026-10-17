defmodule Kinoko.Lang.Cid do
  @moduledoc "Content identifiers: sha256 over the version tag and a declaration's canonical text."

  alias Kinoko.Lang.Format

  @version "yabu/1"

  @spec version() :: String.t()
  def version, do: @version

  @doc "64 lowercase hex characters; layout and line endings do not matter, content does."
  @spec of(Kinoko.Lang.Ast.decl()) :: String.t()
  def of(decl) do
    of_text(Format.decl(decl))
  end

  @doc """
  The CID of a declaration's stored canonical text: what `of/1` gave the
  declaration it was formatted from, whatever the parser makes of the text
  today.
  """
  @spec of_text(String.t()) :: String.t()
  def of_text(text) do
    :sha256 |> :crypto.hash([@version, "\n", text]) |> Base.encode16(case: :lower)
  end
end
