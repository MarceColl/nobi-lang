defmodule Kinoko.Site.SamplesTest do
  @moduledoc """
  The homepage's code sample (site/samples/counter.yabu) is real: it is
  staged into a fresh universe and must promote.
  """
  use Kinoko.DataCase, async: false

  import Kinoko.UniverseHelpers

  alias Kinoko.Universe

  test "counter.yabu promotes" do
    assert {:promoted, ["counter"]} =
             Universe.stage(
               fresh_universe("site"),
               "counter",
               File.read!("site/samples/counter.yabu")
             )
  end
end
