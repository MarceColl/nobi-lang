defmodule Kinoko.CodeDbTest do
  use Kinoko.DataCase, async: false

  import Kinoko.UniverseHelpers

  alias Kinoko.{Cas, CodeDb, Lang, Universe}

  @g "def A.g() : Int do\n  1\nend"
  @f "def A.f() : Int do\n  A.g()\nend"

  setup do
    %{u: fresh_universe("codedb")}
  end

  # Every binary in a stored term, every atom; fails on anything else
  # (no decl tuples, no text, no positions).
  defp leaves(term) do
    case term do
      t when is_binary(t) ->
        [{:binary, t}]

      t when is_atom(t) ->
        [{:atom, t}]

      t when is_list(t) ->
        Enum.flat_map(t, &leaves/1)

      t when is_tuple(t) ->
        t |> Tuple.to_list() |> Enum.flat_map(&leaves/1)

      t when is_map(t) and not is_struct(t) ->
        Enum.flat_map(t, fn {k, v} -> leaves(k) ++ leaves(v) end)
    end
  end

  test "the persisted row decodes to symbol -> CID only", %{u: u} do
    {:promoted, _} = Universe.stage(u, "p1", @g)

    {:staged, _} =
      Universe.stage(u, "p2", @f <> "\n\ndef A.x() : Int do\n  A.nope()\nend", remove: ["A.g"])

    [%{state: binary} | _] = rows(u)

    durable = CodeDb.stored(binary)

    assert %{commits: [%{ids: ["p1"], entries: [{:live, "A.g", cid}]}], staged: [{"p2", staged}]} =
             durable

    assert [{"A.f", _}, {"A.x", _}, {"A.g", :gone}] = staged

    for leaf <- leaves(:erlang.binary_to_term(binary, [:safe])) do
      case leaf do
        {:atom, a} -> flunk("the stored binary holds the atom #{inspect(a)}")
        {:binary, b} when b in ["commits", "staged", "live", "gone"] -> :ok
        {:binary, b} -> assert b in ["p1", "p2", "A.g", "A.f", "A.x"] or b =~ ~r/^[0-9a-f]{64}$/
      end
    end

    assert Map.has_key?(Cas.get([cid]), cid)
  end

  test "decode rebuilds the universe from the CAS" do
    staged_src = @f <> "\n\ndef A.y() : Int do\n  A.z()\nend"
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p1", @g)
    {u, {:staged, _}} = Lang.stage(u, "p2", staged_src)

    for src <- [@g, staged_src] do
      {:ok, _entries, texts} = Lang.prepare(src)
      :ok = Cas.put(texts)
    end

    durable = Lang.durable(u)
    %{u: restored} = durable |> CodeDb.encode() |> CodeDb.decode()
    assert Lang.durable(restored) == durable
    assert Lang.staged(restored) == Lang.staged(u)
    assert Lang.symbols(restored) == Lang.symbols(u)
  end

  # The canonical text an older parser stored for JSX text over several
  # lines: the text kept its inner newline. Parsed today it joins to "one
  # two", which formats (and so hashes) differently.
  @old_view "def A.v() : Html<A.Msg> do\n  <p>\n    one\n    two\n  </p>\nend"
  @msg "deftype A.Msg do\n  Go\nend"

  defp text_cid(text),
    do: :crypto.hash(:sha256, ["yabu/1", "\n", text]) |> Base.encode16(case: :lower)

  defp old_shape_durable do
    {:ok, _, [{msg_cid, _}] = texts} = Lang.prepare(@msg)
    view_cid = text_cid(@old_view)
    :ok = Cas.put([{view_cid, @old_view} | texts])

    {view_cid,
     %{
       commits: [%{ids: ["old"], entries: [{:live, "A.Msg", msg_cid}, {:live, "A.v", view_cid}]}],
       staged: []
     }}
  end

  test "text stored in an older canonical shape restores under its stored CID" do
    {view_cid, durable} = old_shape_durable()
    {:ok, [decl]} = Lang.parse(@old_view)
    refute Lang.cid(decl) == view_cid

    %{u: restored} = durable |> CodeDb.encode() |> CodeDb.decode()
    assert Lang.durable(restored) == durable
    assert %{cid: ^view_cid} = Enum.find(Lang.symbols(restored), &(&1.name == "A.v"))
  end

  test "a universe stored in the older shape boots healthy and keeps its CIDs", %{u: u} do
    {view_cid, durable} = old_shape_durable()
    store_durable(u, durable)

    assert Universe.health(u) == :ok
    assert {:ok, html, _} = Universe.eval(u, "A.v()")
    assert inspect(html) =~ ~s("one two")

    {:promoted, _} = Universe.stage(u, "more", @g)
    [%{state: binary} | _] = rows(u)
    assert %{commits: [%{entries: entries} | _]} = CodeDb.stored(binary)
    assert {:live, "A.v", view_cid} in entries
  end

  test "decode refuses a CAS text that does not hash to its CID" do
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p1", @g)
    [%{cid: cid}] = Lang.symbols(u)
    Cas.put([{cid, "def A.g() : Int do\n  2\nend"}])
    binary = u |> Lang.durable() |> CodeDb.encode()

    error = assert_raise RuntimeError, fn -> CodeDb.decode(binary) end
    assert error.message =~ cid
    assert error.message =~ "does not hash to its CID"
  end

  test "decode raises naming the CID when a CAS row is missing" do
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p1", @g)
    [%{cid: cid}] = Lang.symbols(u)
    binary = u |> Lang.durable() |> CodeDb.encode()

    error = assert_raise RuntimeError, fn -> CodeDb.decode(binary) end
    assert error.message =~ cid
  end

  test "decode raises naming the CID when a CAS text does not parse" do
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p1", @g)
    [%{cid: cid}] = Lang.symbols(u)
    Cas.put([{cid, "def ((("}])
    binary = u |> Lang.durable() |> CodeDb.encode()

    error = assert_raise RuntimeError, fn -> CodeDb.decode(binary) end
    assert error.message =~ cid
    assert error.message =~ "parse"
  end

  test "decode raises naming the CID when a CAS text holds two declarations" do
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p1", @g)
    [%{cid: cid}] = Lang.symbols(u)
    Cas.put([{cid, @g <> "\n\n" <> @f}])
    binary = u |> Lang.durable() |> CodeDb.encode()

    error = assert_raise RuntimeError, fn -> CodeDb.decode(binary) end
    assert error.message =~ cid
  end

  test "a second start under a running key is :already_started", %{u: u} do
    start = fn -> Kinoko.PersistentElmGenServer.start(CodeDb, nil, key: CodeDb.key(u)) end
    assert {:ok, pid} = start.()
    assert {:error, {:already_started, ^pid}} = start.()
    assert pid(u) == pid
  end
end
