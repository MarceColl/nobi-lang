defmodule Nobi.Lang.RoutesCodegenTest do
  @moduledoc "Route tables in images and the pure matcher."
  use ExUnit.Case, async: false

  alias Nobi.Lang
  alias Nobi.Lang.{Codegen, Routes}

  @forum File.read!("test/fixtures/nobi/forum.nobi")
  @uuid "123e4567-e89b-12d3-a456-426614174000"

  @table [
    %{segments: [], app: "Home", params: []},
    %{segments: [{:lit, "post"}, {:param, "id"}], app: "Post", params: [{"id", "Uuid"}]},
    %{segments: [{:lit, "n"}, {:param, "n"}], app: "Num", params: [{"n", "Int"}]},
    %{segments: [{:lit, "u"}, {:param, "s"}], app: "Str", params: [{"s", "String"}]},
    %{segments: [{:lit, "n"}, {:param, "x"}], app: "Shadowed", params: [{"x", "String"}]},
    %{
      segments: [{:lit, "c"}, {:param, "b"}, {:param, "a"}],
      app: "Two",
      params: [{"a", "Int"}, {"b", "String"}]
    }
  ]

  test "the forum image exports its route table with init's param types" do
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p", @forum)
    {:ok, %{module: mod, binary: bin}} = u |> Lang.image()
    {:module, ^mod} = :code.load_binary(mod, ~c"nobi", bin)
    on_exit(fn -> :code.purge(mod) && :code.delete(mod) && :code.purge(mod) end)

    assert %{"Forum" => [home, post, settings]} = mod.__nobi__(:routes)
    assert %{segments: [], app: "Forum.Threads", params: []} = home

    assert %{
             segments: [{:lit, "post"}, {:param, "id"}],
             app: "Forum.Post",
             params: [{"id", "Uuid"}]
           } = post

    assert %{segments: [{:lit, "settings"}], app: "Forum.Settings"} = settings

    assert {:ok, "Forum.Post", [{:uuid, @uuid}]} =
             Routes.match(mod.__nobi__(:routes)["Forum"], "/post/" <> @uuid)
  end

  test "an image without routes has an empty table" do
    assert Codegen.module_name(String.duplicate("a", 40))
    {u, {:promoted, _}} = Lang.stage(Lang.new(), "p", "def A.f() : Int do 1 end")
    {:ok, %{module: mod, binary: bin}} = Lang.image(u)
    {:module, ^mod} = :code.load_binary(mod, ~c"nobi", bin)
    on_exit(fn -> :code.purge(mod) && :code.delete(mod) && :code.purge(mod) end)
    assert mod.__nobi__(:routes) == %{}
  end

  describe "match/2" do
    test "root and literals" do
      assert {:ok, "Home", []} = Routes.match(@table, "/")
      assert :not_found = Routes.match(@table, "")
      assert :not_found = Routes.match(@table, "nope")
      assert :not_found = Routes.match(@table, "/nope")
      assert :not_found = Routes.match(@table, "//")
    end

    test "params by type" do
      assert {:ok, "Post", [{:uuid, @uuid}]} = Routes.match(@table, "/post/#{@uuid}")
      assert {:ok, "Num", [42]} = Routes.match(@table, "/n/42")
      assert {:ok, "Num", [-7]} = Routes.match(@table, "/n/-7")
      assert {:ok, "Num", [0]} = Routes.match(@table, "/n/0")
      assert {:ok, "Str", ["hi"]} = Routes.match(@table, "/u/hi")
    end

    test "args follow init's order, not the pattern's" do
      assert {:ok, "Two", [3, "x"]} = Routes.match(@table, "/c/x/3")
    end

    test "first match wins; a failed parse falls through to later entries" do
      assert {:ok, "Num", [1]} = Routes.match(@table, "/n/1")
      assert {:ok, "Shadowed", ["abc"]} = Routes.match(@table, "/n/abc")
    end

    test "Int rejects overflow, signs, leading zeros, non-digits" do
      assert {:ok, "Num", [9_223_372_036_854_775_807]} =
               Routes.match(@table, "/n/9223372036854775807")

      assert {:ok, "Num", [-9_223_372_036_854_775_808]} =
               Routes.match(@table, "/n/-9223372036854775808")

      for bad <- ["9223372036854775808", "+1", "007", "-0", "1.0", ""] do
        refute match?({:ok, "Num", _}, Routes.match(@table, "/n/" <> bad)), bad
      end

      assert :not_found = Routes.match(Enum.take(@table, 3), "/n/abc")
    end

    test "Uuid must be canonical lowercase" do
      assert :not_found = Routes.match(@table, "/post/" <> String.upcase(@uuid))
      assert :not_found = Routes.match(@table, "/post/123")
      assert :not_found = Routes.match(@table, "/post/" <> String.replace(@uuid, "-", ""))
    end

    test "trailing slash" do
      assert {:ok, "Num", [1]} = Routes.match(@table, "/n/1/")
      assert :not_found = Routes.match(@table, "/n/1//")
      assert :not_found = Routes.match(@table, "/n//1")
    end

    test "percent-decoding" do
      assert {:ok, "Str", ["a b/c"]} = Routes.match(@table, "/u/a%20b%2Fc")
      assert {:ok, "Str", ["é"]} = Routes.match(@table, "/u/%C3%A9")
      assert :not_found = Routes.match(@table, "/u/%zz")
      assert :not_found = Routes.match(@table, "/u/%FF")
      assert {:ok, "Num", [5]} = Routes.match(@table, "/%6E/5")
    end
  end

  describe "path/3" do
    test "builds and encodes" do
      assert {:ok, "/"} = Routes.path(@table, "Home", [])
      assert {:ok, "/n/-3"} = Routes.path(@table, "Num", [-3])
      assert {:ok, "/post/" <> @uuid} = Routes.path(@table, "Post", [{:uuid, @uuid}])
      assert {:ok, "/u/a%20b%2Fc%3F"} = Routes.path(@table, "Str", ["a b/c?"])
      assert {:ok, "/c/x/3"} = Routes.path(@table, "Two", [3, "x"])
    end

    test "errors" do
      assert :error = Routes.path(@table, "Nowhere", [])
      assert :error = Routes.path(@table, "Num", [])
      assert :error = Routes.path(@table, "Num", ["1"])
      assert :error = Routes.path(@table, "Str", [""])
      assert :error = Routes.path(@table, "Post", [{:uuid, "nope"}])
    end

    test "falls through entries of one app and skips shadowed ones" do
      table = [
        %{segments: [{:lit, "a"}, {:param, "x"}], app: "A", params: [{"x", "Int"}]},
        %{segments: [{:lit, "b"}, {:param, "x"}], app: "A", params: [{"x", "String"}]},
        %{segments: [{:lit, "s"}, {:param, "x"}], app: "S", params: [{"x", "String"}]},
        %{segments: [{:lit, "s"}, {:param, "x"}], app: "T", params: [{"x", "String"}]}
      ]

      assert {:ok, "/a/1"} = Routes.path(table, "A", [1])
      assert {:ok, "/b/s"} = Routes.path(table, "A", ["s"])
      assert :error = Routes.path(table, "A", [{:uuid, "x"}])
      assert {:ok, "/s/q"} = Routes.path(table, "S", ["q"])
      assert :error = Routes.path(table, "T", ["q"])
    end

    test "dot-only String values are neither matched nor built" do
      assert :not_found = Routes.match([Enum.at(@table, 3)], "/u/..")
      assert :not_found = Routes.match([Enum.at(@table, 3)], "/u/.")
      assert :not_found = Routes.match([Enum.at(@table, 3)], "/u/%2E%2E")
      assert :error = Routes.path(@table, "Str", [".."])
      assert {:ok, "/u/a.b"} = Routes.path(@table, "Str", ["a.b"])
    end

    test "mismatched pattern and init params raise" do
      bad = [%{segments: [{:param, "x"}], app: "A", params: []}]
      assert_raise ArgumentError, fn -> Routes.match(bad, "/1") end
      assert_raise ArgumentError, fn -> Routes.path(bad, "A", []) end
    end

    test "round-trips with match" do
      cases = [
        {"Home", []},
        {"Num", [0]},
        {"Num", [9_223_372_036_854_775_807]},
        {"Num", [-9_223_372_036_854_775_808]},
        {"Post", [{:uuid, @uuid}]},
        {"Str", ["a b/c?é%#"]},
        {"Two", [12, "q/r"]}
      ]

      for {app, args} <- cases do
        assert {:ok, p} = Routes.path(@table, app, args)
        assert {:ok, ^app, ^args} = Routes.match(@table, p)
      end
    end
  end
end
