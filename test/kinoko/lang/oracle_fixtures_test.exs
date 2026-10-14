defmodule Kinoko.Lang.OracleFixturesTest do
  use ExUnit.Case, async: true

  test "the golden files are whole" do
    assert length(YabuOracle.corpus()) == 4
    assert length(YabuOracle.generated()) == 300
    assert length(YabuOracle.ill_typed()) == 307
    refute Enum.any?(YabuOracle.every_source(), fn {_, s} -> s =~ ~r/\) : Html do/ end)
  end
end
