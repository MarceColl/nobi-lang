defmodule Nobi.Lang.OracleFixturesTest do
  use ExUnit.Case, async: true

  test "the golden files are whole" do
    assert length(NobiOracle.corpus()) == 4
    assert length(NobiOracle.generated()) == 300
    assert length(NobiOracle.ill_typed()) == 307
    refute Enum.any?(NobiOracle.every_source(), fn {_, s} -> s =~ ~r/\) : Html do/ end)
  end
end
