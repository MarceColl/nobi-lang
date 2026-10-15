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

    durable = :erlang.binary_to_term(binary, [:safe])

    assert %{commits: [%{ids: ["p1"], entries: [{:live, "A.g", cid}]}], staged: [{"p2", staged}]} =
             durable

    assert [{"A.f", _}, {"A.x", _}, {"A.g", :gone}] = staged

    for leaf <- leaves(durable) do
      case leaf do
        {:atom, a} -> assert a in [:commits, :staged, :ids, :entries, :live, :gone]
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

    durable = CodeDb.durable(u)
    restored = durable |> CodeDb.encode() |> CodeDb.decode()
    assert Lang.durable(restored) == durable
    assert Lang.staged(restored) == Lang.staged(u)
    assert Lang.symbols(restored) == Lang.symbols(u)
  end

  test "decode raises naming the CID when a CAS row is missing" do
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p1", @g)
    [%{cid: cid}] = Lang.symbols(u)
    binary = u |> CodeDb.durable() |> CodeDb.encode()

    error = assert_raise RuntimeError, fn -> CodeDb.decode(binary) end
    assert error.message =~ cid
  end

  test "decode raises naming the CID when a CAS text does not parse" do
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p1", @g)
    [%{cid: cid}] = Lang.symbols(u)
    Cas.put([{cid, "def ((("}])
    binary = u |> CodeDb.durable() |> CodeDb.encode()

    error = assert_raise RuntimeError, fn -> CodeDb.decode(binary) end
    assert error.message =~ cid
    assert error.message =~ "parse"
  end

  test "decode raises naming the CID when a CAS text holds two declarations" do
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p1", @g)
    [%{cid: cid}] = Lang.symbols(u)
    Cas.put([{cid, @g <> "\n\n" <> @f}])
    binary = u |> CodeDb.durable() |> CodeDb.encode()

    error = assert_raise RuntimeError, fn -> CodeDb.decode(binary) end
    assert error.message =~ cid
  end

  test "a start that loses the race for the key is :ignore, not an error", %{u: u} do
    assert {:ok, pid} = CodeDb.start(u)
    assert :ignore = CodeDb.start(u)
    assert pid(u) == pid
  end
end
