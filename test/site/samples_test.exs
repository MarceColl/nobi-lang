defmodule Nobi.Site.SamplesTest do
  @moduledoc """
  The homepage's code sample (site/samples/counter.nobi) is real: it is
  staged into a fresh universe and must promote.
  """
  use Nobi.DataCase, async: false

  import Nobi.UniverseHelpers

  alias Nobi.Universe

  test "counter.nobi promotes" do
    assert {:promoted, ["counter"]} =
             Universe.stage(
               fresh_universe("site"),
               "counter",
               File.read!("site/samples/counter.nobi")
             )
  end
end
