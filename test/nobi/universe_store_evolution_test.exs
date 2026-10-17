defmodule Nobi.UniverseStoreEvolutionTest do
  @moduledoc """
  Review Focus 4 of the store piece, through `Nobi.Universe` staging: a
  committed stored model retyped, stripped of a field, or given a field with
  neither a default nor `Option` is refused with the exact reason, stays
  staged, and never promotes, also after the universe restarts from
  storage. The rule's every case is `Nobi.Lang.StoreLangTest`'s.
  """
  use Nobi.DataCase, async: false

  import Nobi.UniverseHelpers

  alias Nobi.Universe

  @v1 "defmodel Forum.Post do\n  id : Uuid\n  title : String\nend"

  setup do
    u = fresh_universe()
    {:promoted, ["v1"]} = Universe.stage(u, "v1", @v1)
    %{u: u}
  end

  defp refused(u, id, source, message) do
    assert {:staged, [%{name: "Forum.Post", code: "model-evolution", message: ^message}]} =
             Universe.stage(u, id, source)

    assert %{id: ^id, reasons: [%{code: "model-evolution", message: ^message}]} =
             Enum.find(Universe.staged(u), &(&1.id == id))

    assert {:ok, @v1} = Universe.read(u, "Forum.Post")
  end

  test "each violation is refused with its reason and never promoted", %{u: u} do
    refused(
      u,
      "retype",
      "defmodel Forum.Post do\n  id : Uuid\n  title : Int\nend",
      "Forum.Post.title was String, cannot become Int; add a new field instead"
    )

    refused(
      u,
      "remove",
      "defmodel Forum.Post do\n  id : Uuid\nend",
      "cannot remove Forum.Post.title; leave it in place"
    )

    refused(
      u,
      "mandatory",
      "defmodel Forum.Post do\n  id : Uuid\n  title : String\n  replies : Int\nend",
      "Forum.Post: new field replies : Int needs a default (replies : Int = 0) or an Option type"
    )

    assert [%{ids: ["v1"]}] = Universe.history(u)
  end

  test "an allowed change promotes", %{u: u} do
    v2 = "defmodel Forum.Post do\n  id : Uuid\n  title : String\n  replies : Int = 0\nend"
    assert {:promoted, ["v2"]} = Universe.stage(u, "v2", v2)
    assert {:ok, ^v2} = Universe.read(u, "Forum.Post")
  end

  test "after a restart the committed model still constrains, and a staged violation keeps its reason",
       %{u: u} do
    retype = "defmodel Forum.Post do\n  id : Uuid\n  title : Int\nend"
    {:staged, _} = Universe.stage(u, "retype", retype)
    stop(u)

    assert Universe.health(u) == :ok

    assert [%{id: "retype", reasons: [%{code: "model-evolution"}]}] = Universe.staged(u)

    refused(
      u,
      "remove",
      "defmodel Forum.Post do\n  id : Uuid\nend",
      "cannot remove Forum.Post.title; leave it in place"
    )
  end
end
