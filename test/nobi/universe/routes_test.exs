defmodule Nobi.Universe.RoutesTest do
  @moduledoc "A product with a route table, staged through `Nobi.Universe`."
  use Nobi.DataCase, async: false

  import Nobi.UniverseHelpers

  alias Nobi.Universe

  @forum File.read!("test/fixtures/nobi/forum.nobi")

  test "the forum fixture promotes, and its apps still run" do
    u = fresh_universe()
    assert {:promoted, ["forum"]} = Universe.stage(u, "forum", @forum)

    symbols = Map.new(Universe.symbols(u), &{&1.symbol, &1.signature})
    assert symbols["Forum"] =~ ~s(routes {"/" -> Forum.Threads)
    assert {:ok, "defroutes Forum do\n" <> _} = Universe.read(u, "Forum")

    # The image compiles with a route table and a navigating update in it.
    assert {:ok, _, _} = Universe.call(u, "Forum.Threads.init", [], [])

    # Placeholder until the host runs it: an effect naming the app, then
    # init's arguments.
    done =
      ~s|Forum.Settings.update(Forum.Settings.Msg.Done, %Forum.Settings.Model{name: "", saved: false})|

    assert {:ok, {_model, cmd}, _type} = Universe.eval(u, done, [])
    assert cmd == {:cmd, {:effect, "Cmd.navigate", nil, ["Forum.Threads"]}}
  end

  test "renaming init's parameter re-checks the route table" do
    u = fresh_universe()
    assert {:promoted, ["forum"]} = Universe.stage(u, "forum", @forum)

    renamed =
      "def Forum.Post.init(slug : Uuid) : (Forum.Post.Model, Cmd<Forum.Post.Msg>) do\n" <>
        "  (%Forum.Post.Model{post_id: slug, topic: Option.None, replies: [], draft: \"\", error: \"\"}, Cmd.none())\nend"

    assert {:staged, reasons} = Universe.stage(u, "rename", renamed)
    assert [%{name: "Forum", code: "route-mismatch"}] = reasons
  end
end
