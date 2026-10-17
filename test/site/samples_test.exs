defmodule Kinoko.Site.SamplesTest do
  @moduledoc """
  The homepage's code samples (site/samples/*.yabu) are real: each is staged
  into a fresh universe and must reach its expected verdict. What Kinoko
  prints for each verdict (the MCP `stage_patch` text) is kept in
  site/samples/verdicts/*.txt, which `mix site.build` shows on the page; this
  test fails when the live text drifts from the fixture. Rerun with
  `SITE_RECORD=1` to rewrite the fixtures from a live run.
  """
  use KinokoWeb.ConnCase, async: false

  import Kinoko.UniverseHelpers

  alias Kinoko.Universe

  @samples "site/samples"
  @verdicts "site/samples/verdicts"

  defp sample(name), do: File.read!(Path.join(@samples, name))

  defp stage_patch(conn, u, id, source) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "stage_patch",
        "arguments" => %{"universe" => u, "id" => id, "source" => source}
      }
    }

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", Jason.encode!(msg))

    %{"result" => %{"content" => [%{"text" => text}], "isError" => false}} =
      Jason.decode!(conn.resp_body)

    text
  end

  # The printed verdict must equal its fixture (or, with SITE_RECORD=1,
  # becomes it).
  defp assert_fixture(name, text) do
    path = Path.join(@verdicts, name)

    if System.get_env("SITE_RECORD") == "1" do
      File.mkdir_p!(@verdicts)
      File.write!(path, text <> "\n")
    end

    assert File.read!(path) == text <> "\n", "#{path} drifted from the live verdict"
  end

  describe "verdicts (Kinoko.Universe)" do
    test "counter.yabu promotes" do
      assert {:promoted, ["counter"]} =
               Universe.stage(fresh_universe("site"), "counter", sample("counter.yabu"))
    end

    test "store.yabu promotes fresh, and as an add-only evolution of store_v1.yabu" do
      assert {:promoted, ["store"]} =
               Universe.stage(fresh_universe("site"), "store", sample("store.yabu"))

      u = fresh_universe("site")
      assert {:promoted, ["v1"]} = Universe.stage(u, "v1", sample("store_v1.yabu"))
      assert {:promoted, ["store"]} = Universe.stage(u, "store", sample("store.yabu"))
    end

    test "a new field without a default is refused as a model evolution" do
      u = fresh_universe("site")
      assert {:promoted, ["v1"]} = Universe.stage(u, "v1", sample("store_v1.yabu"))

      no_default = String.replace(sample("store.yabu"), "replies : Int = 0", "replies : Int")
      assert {:staged, reasons} = Universe.stage(u, "store", no_default)
      assert Enum.any?(reasons, &(&1.code == "model-evolution"))
    end

    test "mistake.yabu stays staged with a type mismatch" do
      assert {:staged, [%{code: "mismatch", name: "Counter.label", message: message}]} =
               Universe.stage(fresh_universe("site"), "mistake", sample("mistake.yabu"))

      assert message == "type mismatch: expected String, got Int in `count`"
    end
  end

  describe "printed verdicts (MCP stage_patch, kept as fixtures)" do
    test "each sample's printed verdict matches its fixture", %{conn: conn} do
      for {file, id} <- [{"counter.yabu", "counter"}, {"mistake.yabu", "mistake"}] do
        text = stage_patch(conn, fresh_universe("site"), id, sample(file))
        assert_fixture(id <> ".txt", text)
      end

      u = fresh_universe("site")
      assert stage_patch(conn, u, "v1", sample("store_v1.yabu")) == "promoted: v1"
      assert_fixture("store.txt", stage_patch(conn, u, "store", sample("store.yabu")))
    end
  end
end
