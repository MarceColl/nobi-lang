defmodule Kinoko.Lang.LinksTest do
  # Universes write to SQLite: not async.
  use Kinoko.DataCase, async: false

  import Kinoko.UniverseHelpers

  alias Kinoko.Universe

  @upper "0B6F9A52-4D1E-4C3A-9F7E-2A1B3C4D5E6F"
  @lower "0b6f9a52-4d1e-4c3a-9f7e-2a1b3c4d5e6f"

  @app """
  defmodel L.Model do
    id : Uuid
  end

  deftype L.Msg do
    Go
  end

  def L.init(id : Uuid) : (L.Model, Cmd<L.Msg>) do
    (%L.Model{}, Cmd.none())
  end

  def L.update(msg : L.Msg, model : L.Model) : (L.Model, Cmd<L.Msg>) do
    (model, Cmd.none())
  end

  def L.view(model : L.Model) : Html<L.Msg> do
    <p>hi</p>
  end

  defapp L
  """

  defp staged(u, source) do
    assert {:staged, reasons} = Universe.stage(u, "p", source)
    reasons
  end

  setup do
    u = fresh_universe("links")
    assert {:promoted, _} = Universe.stage(u, "app", @app)
    %{u: u}
  end

  describe "Uuid" do
    test "to_string and parse round trip, in canonical lowercase", %{u: u} do
      expr = """
      case Uuid.parse("#{@upper}") do
        Option.Some(id) -> (Uuid.to_string(id), Uuid.parse(Uuid.to_string(id)) == Option.Some(id))
        Option.None -> ("", false)
      end
      """

      assert {:ok, {@lower, true}, _} = Universe.eval(u, expr)
    end

    test "parse answers None for what is not a UUID", %{u: u} do
      for bad <- ["", "nope", String.slice(@lower, 0..34), @lower <> "0", " " <> @lower] do
        assert {:ok, {:var, "Option", "None", []}, _} =
                 Universe.eval(u, "Uuid.parse(#{inspect(bad)})")
      end
    end
  end

  describe "Html.href" do
    test "checks like Cmd.navigate: the app and init's arguments", %{u: u} do
      ok = """
      def L.link(id : Uuid) : Html<L.Msg> do
        <a href={Html.href(L, id)}>go</a>
      end
      """

      assert {:promoted, _} = Universe.stage(u, "ok", ok)

      wrong_type = """
      def L.bad(n : Int) : Html<L.Msg> do
        <a href={Html.href(L, n)}>go</a>
      end
      """

      assert [%{code: "bad-href", message: m}] = staged(u, wrong_type)
      assert m =~ "takes `id : Uuid`"

      wrong_count = "def L.bad() : Html<L.Msg> do\n  <a href={Html.href(L)}>go</a>\nend"
      assert [%{code: "bad-href"}] = staged(u, wrong_count)

      not_app =
        "def L.bad(id : Uuid) : Html<L.Msg> do\n  <a href={Html.href(L.Model, id)}>go</a>\nend"

      assert [%{code: "bad-href"}] = staged(u, not_app)
    end

    test "goes only in an href, and is no data", %{u: u} do
      in_class =
        "def L.bad(id : Uuid) : Html<L.Msg> do\n  <a class={Html.href(L, id)}>go</a>\nend"

      assert [%{code: "mismatch", message: m}] = staged(u, in_class)
      assert m =~ "goes in an `href`"

      as_child = "def L.bad(id : Uuid) : Html<L.Msg> do\n  <p>{Html.href(L, id)}</p>\nend"
      assert [_ | _] = staged(u, as_child)

      field = "defmodel L.Keep do\n  to : Href\nend"
      assert [%{code: "invalid-model-field"}] = staged(u, field)
    end

    test "JSON.stringify refuses a link with Err, never a crash", %{u: u} do
      expr = """
      case Uuid.parse("#{@lower}") do
        Option.Some(id) -> JSON.stringify((Html.href(L, id), 1))
        Option.None -> Result.Err("none")
      end
      """

      assert {:ok, {:var, "Result", "Err", [why]}, _} = Universe.eval(u, expr)
      assert why =~ "cannot encode a link (Html.href) as JSON"
    end

    test "evaluates to a link that shows as its call", %{u: u} do
      expr = """
      case Uuid.parse("#{@lower}") do
        Option.Some(id) -> L.link(id)
        Option.None -> <p>none</p>
      end
      """

      link = "def L.link(id : Uuid) : Html<L.Msg> do\n  <a href={Html.href(L, id)}>go</a>\nend"
      assert {:promoted, _} = Universe.stage(u, "link", link)
      assert {:ok, html, type} = Universe.eval(u, expr)
      assert Kinoko.Exec.show(html, type) =~ "Html.href(L, <uuid #{@lower}>)"
    end
  end
end
