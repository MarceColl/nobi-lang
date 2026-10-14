defmodule Kinoko.Lang.ParserPerfTest do
  # Not async: the timing must not compete with other test modules.
  use ExUnit.Case, async: false

  alias Kinoko.Lang.Parser

  test "a 5 MB source parses within 3 seconds" do
    src = String.duplicate("def A.f() : Int do\n  1\nend\n\n", 200_000)
    {us, result} = :timer.tc(fn -> Parser.program(src) end)
    # duplicates are the universe's concern, not the parser's
    assert {:ok, _} = result
    assert us < 3_000_000
  end
end
