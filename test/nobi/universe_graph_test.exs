defmodule Nobi.UniverseGraphTest do
  @moduledoc """
  `Nobi.Universe.graph/1`: the apps, the stored models, and which app
  reads or writes which model, through every def its loop reaches.
  """
  use Nobi.DataCase, async: false

  import ExUnit.CaptureLog
  import Nobi.UniverseHelpers

  alias Nobi.Universe

  @forum File.read!("test/fixtures/nobi/forum.nobi")

  # Two apps write `S.Note` only through the shared helper `S.note` (B one
  # def further away); C deletes a tag by name (`Tx.delete`); nothing
  # reaches `S.orphan`, so its read of `S.Tag` is nobody's; D's tx reads a
  # tag (`Store.get`) and writes it (`Tx.update`).
  @shared """
  defmodel S.Note do
    id : Uuid
    text : String
  end

  defmodel S.Tag do
    id : Uuid
    name : String
  end

  def S.note(text : String) : Tx.Op do
    Tx.insert(%S.Note{text: text})
  end

  def S.orphan(s : Store) : List<S.Tag> do
    Store.list(s)
  end

  defmodel S.A.Model do
    n : Int
  end

  deftype S.A.Msg do
    Add | Done(Result<(List<Uuid>, Int), String>)
  end

  def S.A.init() : (S.A.Model, Cmd<S.A.Msg>) do
    (%S.A.Model{n: 0}, Cmd.none())
  end

  def S.A.update(msg : S.A.Msg, model : S.A.Model) : (S.A.Model, Cmd<S.A.Msg>) do
    case msg do
      S.A.Msg.Add -> (model, Cmd.store.tx(fn (s : Store) -> ([S.note("a")], 0) end, S.A.Msg.Done))
      S.A.Msg.Done(r) -> (model, Cmd.none())
    end
  end

  def S.A.view(model : S.A.Model) : Html<S.A.Msg> do
    <p>{model.n}</p>
  end

  defapp S.A

  defmodel S.B.Model do
    n : Int
  end

  deftype S.B.Msg do
    Add | Done(Result<(List<Uuid>, Int), String>)
  end

  def S.B.go(text : String) : Cmd<S.B.Msg> do
    Cmd.store.tx(fn (s : Store) -> ([S.note(text)], 0) end, S.B.Msg.Done)
  end

  def S.B.init() : (S.B.Model, Cmd<S.B.Msg>) do
    (%S.B.Model{n: 0}, S.B.go("b"))
  end

  def S.B.update(msg : S.B.Msg, model : S.B.Model) : (S.B.Model, Cmd<S.B.Msg>) do
    (model, Cmd.none())
  end

  def S.B.view(model : S.B.Model) : Html<S.B.Msg> do
    <p>{model.n}</p>
  end

  defapp S.B

  defmodel S.C.Model do
    n : Int
  end

  deftype S.C.Msg do
    Drop(Uuid) | Done(Result<(List<Uuid>, Int), String>)
  end

  def S.C.init() : (S.C.Model, Cmd<S.C.Msg>) do
    (%S.C.Model{n: 0}, Cmd.none())
  end

  def S.C.update(msg : S.C.Msg, model : S.C.Model) : (S.C.Model, Cmd<S.C.Msg>) do
    case msg do
      S.C.Msg.Drop(id) -> (model, Cmd.store.tx(fn (s : Store) -> ([Tx.delete(S.Tag, id)], 0) end, S.C.Msg.Done))
      S.C.Msg.Done(r) -> (model, Cmd.none())
    end
  end

  def S.C.view(model : S.C.Model) : Html<S.C.Msg> do
    <p>{model.n}</p>
  end

  defapp S.C

  defmodel S.D.Model do
    n : Int
  end

  deftype S.D.Msg do
    Rename(Uuid) | Done(Result<(List<Uuid>, Int), String>)
  end

  def S.D.init() : (S.D.Model, Cmd<S.D.Msg>) do
    (%S.D.Model{n: 0}, Cmd.none())
  end

  def S.D.update(msg : S.D.Msg, model : S.D.Model) : (S.D.Model, Cmd<S.D.Msg>) do
    case msg do
      S.D.Msg.Rename(id) ->
        (model, Cmd.store.tx(
          fn (s : Store) ->
            case Store.get(s, id) do
              Option.Some(t) -> ([Tx.update(id, %S.Tag{t | name: "x"})], 1)
              Option.None -> ([], 0)
            end
          end,
          S.D.Msg.Done
        ))
      S.D.Msg.Done(r) -> (model, Cmd.none())
    end
  end

  def S.D.view(model : S.D.Model) : Html<S.D.Msg> do
    <p>{model.n}</p>
  end

  defapp S.D
  """

  setup do
    %{u: fresh_universe()}
  end

  defp edge(from, to, kind), do: %{from: from, to: to, kind: kind}

  defp graph!(universe_or_at) do
    assert %{apps: _, stores: _, edges: _} = graph = Universe.graph(universe_or_at)
    graph
  end

  describe "forum" do
    setup %{u: u} do
      assert {:promoted, _} = Universe.stage(u, "forum", @forum)
      %{graph: graph!(u)}
    end

    test "apps with their route patterns, stored models with their fields", %{graph: graph} do
      assert graph.apps == [
               %{symbol: "Forum.Post", routes: ["/post/:id"]},
               %{symbol: "Forum.Settings", routes: ["/settings"]},
               %{symbol: "Forum.Threads", routes: ["/"]}
             ]

      # Only models with `id : Uuid` are stores; app models are not.
      assert graph.stores == [
               %{symbol: "Forum.Reply", fields: ["id", "topic", "body"]},
               %{symbol: "Forum.Topic", fields: ["id", "title", "replies"]}
             ]
    end

    test "an app inserting into a model writes it", %{graph: graph} do
      assert edge("Forum.Threads", "Forum.Topic", :writes) in graph.edges
    end

    test "an app listing a model reads it", %{graph: graph} do
      assert edge("Forum.Threads", "Forum.Topic", :reads) in graph.edges
      assert edge("Forum.Post", "Forum.Reply", :reads) in graph.edges
    end

    test "a tx's Store.get reads and its Tx ops write, through a helper", %{graph: graph} do
      # Forum.Post.reply: Store.get(Topic), Tx.insert(Reply), Tx.update(Topic).
      assert graph.edges == [
               edge("Forum.Post", "Forum.Reply", :reads),
               edge("Forum.Post", "Forum.Reply", :writes),
               edge("Forum.Post", "Forum.Topic", :reads),
               edge("Forum.Post", "Forum.Topic", :writes),
               edge("Forum.Threads", "Forum.Topic", :reads),
               edge("Forum.Threads", "Forum.Topic", :writes)
             ]
    end
  end

  test "a helper shared by two apps attributes to both; an unreached one to none", %{u: u} do
    assert {:promoted, _} = Universe.stage(u, "shared", @shared)
    graph = graph!(u)

    assert Enum.map(graph.apps, & &1.symbol) == ["S.A", "S.B", "S.C", "S.D"]
    assert Enum.all?(graph.apps, &(&1.routes == []))
    assert Enum.map(graph.stores, & &1.symbol) == ["S.Note", "S.Tag"]

    assert graph.edges == [
             edge("S.A", "S.Note", :writes),
             edge("S.B", "S.Note", :writes),
             edge("S.C", "S.Tag", :writes),
             edge("S.D", "S.Tag", :reads),
             edge("S.D", "S.Tag", :writes)
           ]
  end

  test "a pinned commit answers with that commit's graph", %{u: u} do
    assert {:promoted, _} = Universe.stage(u, "forum", @forum)
    assert {:promoted, _} = Universe.stage(u, "shared", @shared)
    {:ok, one} = Universe.at(u, 1)

    assert Enum.map(graph!(one).apps, & &1.symbol) ==
             ["Forum.Post", "Forum.Settings", "Forum.Threads"]

    assert length(graph!(u).apps) == 7
    # Cached by image hash: asking again answers the same.
    assert graph!(one) == graph!(one)
  end

  test "models/1 gives each model's fields in order, for Nobi.Data", %{u: u} do
    assert {:promoted, _} = Universe.stage(u, "base", @forum)
    assert {:ok, models} = Universe.models(u)
    assert [{"id", _, _}, {"title", _, _}, {"replies", _, 0}] = models["Forum.Topic"]
    assert length(models["Forum.Threads.Model"]) == 3
  end

  test "an empty universe has an empty graph", %{u: u} do
    assert Universe.graph(u) == %{apps: [], stores: [], edges: []}
  end

  test "a degraded universe answers degraded", %{u: u} do
    store_commit(u, "def A.f() : Int do\n  A.g()\nend")

    capture_log(fn ->
      assert {:error, %{code: "degraded", message: m}} = Universe.graph(u)
      assert m =~ "`A.f`"
    end)
  end

  test "an unknown universe or a bad name is refused" do
    assert {:error, :no_such_universe} = Universe.graph("nope-graph")
    assert {:error, :bad_name} = Universe.graph("Not A Name")
  end
end
