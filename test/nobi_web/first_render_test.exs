defmodule NobiWeb.FirstRenderTest do
  use NobiWeb.ConnCase, async: false

  import Nobi.UniverseHelpers
  import Phoenix.LiveViewTest

  alias Nobi.{Deployment, Universe}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir}, do: isolated_data(dir)

  @clock """
  defmodel C.Row do
    id : Uuid
    n : Int
  end

  defmodel C.Model do
    now : Int
    roll : Int
    rows : Int
  end

  deftype C.Msg do
    Tick(Int) | Roll(Int) | Loaded(List<C.Row>)
  end

  def C.init() : (C.Model, Cmd<C.Msg>) do
    (%C.Model{now: 0, roll: 0, rows: 0}, Cmd.batch([Cmd.store.list(C.Msg.Loaded), Cmd.time.now(C.Msg.Tick), Cmd.random.int(1, 6, C.Msg.Roll)]))
  end

  def C.update(msg : C.Msg, model : C.Model) : (C.Model, Cmd<C.Msg>) do
    case msg do
      C.Msg.Tick(t) -> (%C.Model{model | now: t}, Cmd.none())
      C.Msg.Roll(n) -> (%C.Model{model | roll: n}, Cmd.none())
      C.Msg.Loaded(rows) -> (%C.Model{model | rows: List.length(rows)}, Cmd.none())
    end
  end

  def C.view(model : C.Model) : Html<C.Msg> do
    <p><span id="now">{model.now}</span> <span id="roll">{model.roll}</span></p>
  end

  defapp C

  defroutes Main do
    "/" -> C
  end
  """

  test "a static GET renders the time and roll init asked for, not the fallback", %{conn: conn} do
    u = fresh_universe("fr")
    assert {:promoted, _} = Universe.stage(u, "base", @clock)
    :ok = Deployment.create(u, u, "Main", [])

    html = conn |> Map.put(:host, "#{u}.localhost") |> get("/") |> html_response(200)
    [now] = Regex.run(~r/<span id="now">(-?\d+)<\/span>/, html, capture: :all_but_first)
    assert_in_delta String.to_integer(now), System.system_time(:millisecond), 60_000
    [roll] = Regex.run(~r/<span id="roll">(\d+)<\/span>/, html, capture: :all_but_first)
    assert String.to_integer(roll) in 1..6
  end

  @visit """
  defmodel V.Hit do
    id : Uuid
    n : Int
  end

  defmodel V.Model do
    hits : Int
  end

  deftype V.Msg do
    Saved(Uuid) | Loaded(List<V.Hit>)
  end

  def V.init() : (V.Model, Cmd<V.Msg>) do
    (%V.Model{hits: 0}, Cmd.store.insert(%V.Hit{n: 1}, V.Msg.Saved))
  end

  def V.update(msg : V.Msg, model : V.Model) : (V.Model, Cmd<V.Msg>) do
    case msg do
      V.Msg.Saved(id) -> (model, Cmd.store.list(V.Msg.Loaded))
      V.Msg.Loaded(rows) -> (%V.Model{hits: List.length(rows)}, Cmd.none())
    end
  end

  def V.view(model : V.Model) : Html<V.Msg> do
    <span id="hits">{model.hits}</span>
  end

  defapp V

  defroutes Main do
    "/" -> V
  end
  """

  test "a store write init asks for runs once per page load, not in both renders", %{conn: conn} do
    u = fresh_universe("fr")
    assert {:promoted, _} = Universe.stage(u, "base", @visit)
    :ok = Deployment.create(u, u, "Main", [])

    {:ok, view, _html} = live(Map.put(conn, :host, "#{u}.localhost"), "/")
    render(view)
    Process.sleep(200)
    assert [%{model: "V.Hit", rows: 1}] = Nobi.Data.stats(u)
    assert render(view) =~ ~s(<span id="hits">1</span>)
  end

  test "a session that does not say it is connected is not: writes wait" do
    {m, _} = NobiWeb.DeploymentLive.init(%{}, %{"deployment" => "x"})
    refute m.connected?
    {m, _} = NobiWeb.DeploymentLive.init(%{}, %{"elm_connected?" => "true"})
    refute m.connected?
    {m, _} = NobiWeb.DeploymentLive.init(%{}, %{"elm_connected?" => true})
    assert m.connected?
  end
end
