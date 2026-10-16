defmodule Kinoko.DataTest do
  # Each test has its own data directory and real pools: no Ecto sandbox.
  use ExUnit.Case, async: true

  alias Kinoko.Data
  alias Kinoko.Data.Repo

  @uuid {:named, "Uuid"}
  @int {:named, "Int"}
  @str {:named, "String"}
  @bool {:named, "Bool"}
  @none {:var, "Option", "None", []}

  defp some(v), do: {:var, "Option", "Some", [v]}
  defp option(t), do: {:applied, "Option", [t]}
  defp list(t), do: {:applied, "List", [t]}

  @v1 [{"id", @uuid, :none}, {"title", @str, :none}, {"votes", @int, :none}]

  @v2 @v1 ++
        [
          {"pinned", @bool, false},
          {"note", {:applied, "Option", [@str]}, :none},
          {"tags", {:applied, "List", [@str]}, ["x"]},
          {"score", {:applied, "Option", [@int]}, :none},
          {"label", @str, "it's"}
        ]

  setup do
    dir = Path.join(System.tmp_dir!(), "kinoko-data-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      for name <- ["app", "a", "b"], do: Data.close(name, dir: dir)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp open!(dir, name \\ "app") do
    {:ok, repo} = Data.open(name, dir: dir)
    repo
  end

  defp post(fields), do: {:rec, "Forum.Post", fields}

  defp v1_post(title, votes), do: post(%{"title" => title, "votes" => votes})

  defp sql!(repo, sql, params \\ []) do
    Repo.put_dynamic_repo(repo)
    Repo.query!(sql, params).rows
  end

  defp columns(repo, table) do
    for [_cid, name, type, _notnull, default, _pk] <-
          sql!(repo, ~s[PRAGMA table_info("#{table}")]),
        into: %{},
        do: {name, {type, default}}
  end

  describe "open" do
    test "is single-flight under 10 concurrent opens", %{dir: dir} do
      repos =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> Data.open("app", dir: dir) end) end)
        |> Task.await_many()

      assert [{:ok, repo}] = Enum.uniq(repos)
      assert is_pid(repo)
      assert File.exists?(Path.join([dir, "data", "app.db"]))

      tables = sql!(repo, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
      assert ["_kinoko_columns"] in tables
      assert ["_kinoko_tables"] in tables
    end

    test "one file per deployment", %{dir: dir} do
      a = open!(dir, "a")
      b = open!(dir, "b")
      assert a != b
      assert File.exists?(Path.join([dir, "data", "a.db"]))
      assert File.exists?(Path.join([dir, "data", "b.db"]))

      assert {:ok, _} = Data.insert(a, "Forum.Post", @v1, v1_post("hi", 1))
      assert {:ok, [_]} = Data.list(a, "Forum.Post", @v1)
      assert {:ok, []} = Data.list(b, "Forum.Post", @v1)
    end

    test "refuses a name that is no deployment name", %{dir: dir} do
      assert {:error, :bad_name} = Data.open("../etc", dir: dir)
      assert {:error, :bad_name} = Data.open("A b", dir: dir)
    end

    test "uses the WAL journal and the configured pragmas", %{dir: dir} do
      repo = open!(dir)
      assert [["wal"]] = sql!(repo, "PRAGMA journal_mode")
      assert [[1]] = sql!(repo, "PRAGMA foreign_keys")
      # busy_timeout is Exqlite's own busy handler, which PRAGMA busy_timeout
      # does not report: "a locked file is unavailable" covers it.
    end

    test "the data directory defaults to Kinoko.Repo's, under data/" do
      repo_db = Application.fetch_env!(:kinoko, Kinoko.Repo)[:database]
      assert Data.path("app") == Path.join([Path.dirname(repo_db), "data", "app.db"])
    end
  end

  describe "ensure" do
    test "creates the table, then adds columns, with no SQL defaults", %{dir: dir} do
      repo = open!(dir)
      assert :ok = Data.ensure(repo, "Forum.Post", @v1)

      cols = columns(repo, "forum__post")
      assert cols["id"] == {"TEXT", nil}
      assert cols["_seq"] == {"INTEGER", nil}
      assert cols["title"] == {"TEXT", nil}
      assert cols["votes"] == {"INTEGER", nil}
      assert map_size(cols) == 4

      assert :ok = Data.ensure(repo, "Forum.Post", @v2)
      cols = columns(repo, "forum__post")
      # Defaults are read-time (from the reader's signature), never SQL's.
      assert cols["pinned"] == {"INTEGER", nil}
      assert cols["note"] == {"TEXT", nil}
      assert cols["tags"] == {"TEXT", nil}
      assert cols["score"] == {"INTEGER", nil}
      assert cols["label"] == {"TEXT", nil}

      # Idempotent, and never drops: back to v1 keeps every column.
      assert :ok = Data.ensure(repo, "Forum.Post", @v2)
      assert :ok = Data.ensure(repo, "Forum.Post", @v1)
      assert map_size(columns(repo, "forum__post")) == 9
    end

    test "concurrent ensures of one new signature all succeed", %{dir: dir} do
      repo = open!(dir)

      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> Data.ensure(repo, "Forum.Post", @v2) end) end)
        |> Task.await_many()

      assert Enum.uniq(results) == [:ok]
    end
  end

  describe "rows" do
    test "insert mints a v4 id and overwrites the row's", %{dir: dir} do
      repo = open!(dir)
      given = {:uuid, "00000000-0000-0000-0000-000000000000"}
      row = post(%{"id" => given, "title" => "t", "votes" => 2})

      assert {:ok, {:uuid, id} = uuid} = Data.insert(repo, "Forum.Post", @v1, row)
      assert uuid != given
      assert id =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      assert {:ok, post(%{"id" => uuid, "title" => "t", "votes" => 2})} ==
               Data.get(repo, "Forum.Post", @v1, uuid)
    end

    test "list is in insertion order", %{dir: dir} do
      repo = open!(dir)

      ids =
        for i <- 1..5 do
          {:ok, id} = Data.insert(repo, "Forum.Post", @v1, v1_post("p#{i}", i))
          id
        end

      assert {:ok, rows} = Data.list(repo, "Forum.Post", @v1)
      assert Enum.map(rows, fn {:rec, _, f} -> f["id"] end) == ids
      assert Enum.map(rows, fn {:rec, _, f} -> f["votes"] end) == [1, 2, 3, 4, 5]
    end

    test "update replaces the row and keeps its place; a missing id is not-found", %{dir: dir} do
      repo = open!(dir)
      {:ok, a} = Data.insert(repo, "Forum.Post", @v1, v1_post("a", 1))
      {:ok, _} = Data.insert(repo, "Forum.Post", @v1, v1_post("b", 2))

      assert {:ok, ^a} = Data.update(repo, "Forum.Post", @v1, a, v1_post("a2", 10))
      assert {:ok, [first, _]} = Data.list(repo, "Forum.Post", @v1)
      assert first == post(%{"id" => a, "title" => "a2", "votes" => 10})

      missing = {:uuid, "11111111-1111-4111-8111-111111111111"}

      assert {:error, %{code: "not-found"}} =
               Data.update(repo, "Forum.Post", @v1, missing, v1_post("x", 0))
    end

    test "get and delete of a missing id are nil; delete returns the row", %{dir: dir} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "Forum.Post", @v1, v1_post("a", 1))
      missing = {:uuid, "11111111-1111-4111-8111-111111111111"}

      assert {:ok, nil} = Data.get(repo, "Forum.Post", @v1, missing)
      assert {:ok, nil} = Data.delete(repo, "Forum.Post", @v1, missing)

      assert {:ok, post(%{"id" => id, "title" => "a", "votes" => 1})} ==
               Data.delete(repo, "Forum.Post", @v1, id)

      assert {:ok, nil} = Data.get(repo, "Forum.Post", @v1, id)
      assert {:ok, []} = Data.list(repo, "Forum.Post", @v1)
    end

    test "rows written under v1 read under v2 with defaults", %{dir: dir} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "Forum.Post", @v1, v1_post("old", 7))

      assert {:ok, [row]} = Data.list(repo, "Forum.Post", @v2)

      assert row ==
               post(%{
                 "id" => id,
                 "title" => "old",
                 "votes" => 7,
                 "pinned" => false,
                 "note" => @none,
                 "tags" => ["x"],
                 "score" => @none,
                 "label" => "it's"
               })
    end

    test "a changed default applies to rows written before the field", %{dir: dir} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "Forum.Post", @v1, v1_post("old", 7))
      {:ok, {:rec, _, fields}} = Data.get(repo, "Forum.Post", @v2, id)
      assert {fields["pinned"], fields["label"], fields["tags"]} == {false, "it's", ["x"]}

      v3 =
        Enum.map(@v2, fn
          {"pinned", t, _} -> {"pinned", t, true}
          {"label", t, _} -> {"label", t, "new"}
          {"tags", t, _} -> {"tags", t, []}
          other -> other
        end)

      {:ok, {:rec, _, fields}} = Data.get(repo, "Forum.Post", v3, id)
      assert {fields["pinned"], fields["label"], fields["tags"]} == {true, "new", []}
    end

    test "extra columns are ignored by older code, which keeps them on update", %{dir: dir} do
      repo = open!(dir)

      new =
        post(%{
          "title" => "new",
          "votes" => 1,
          "pinned" => true,
          "note" => some("n"),
          "tags" => ["a", "b"],
          "score" => @none,
          "label" => "l"
        })

      {:ok, id} = Data.insert(repo, "Forum.Post", @v2, new)
      assert {:ok, [old]} = Data.list(repo, "Forum.Post", @v1)
      assert old == post(%{"id" => id, "title" => "new", "votes" => 1})

      {:ok, ^id} = Data.update(repo, "Forum.Post", @v1, id, v1_post("edited", 2))
      {:ok, {:rec, _, fields}} = Data.get(repo, "Forum.Post", @v2, id)
      assert fields["title"] == "edited"
      assert fields["tags"] == ["a", "b"]
      assert fields["note"] == some("n")
    end

    test "rows older code inserts read newer fields as their defaults", %{dir: dir} do
      repo = open!(dir)
      :ok = Data.ensure(repo, "Forum.Post", @v2)
      {:ok, id} = Data.insert(repo, "Forum.Post", @v1, v1_post("old", 1))
      {:ok, {:rec, _, fields}} = Data.get(repo, "Forum.Post", @v2, id)
      assert fields["pinned"] == false
      assert fields["score"] == @none
      assert fields["tags"] == ["x"]
    end
  end

  describe "Option and NULL" do
    test "Option round-trips; NULL is None for an Option, the default otherwise", %{dir: dir} do
      repo = open!(dir)

      base = %{
        "title" => "t",
        "votes" => 1,
        "pinned" => true,
        "tags" => [],
        "label" => "l"
      }

      {:ok, a} =
        Data.insert(
          repo,
          "Forum.Post",
          @v2,
          post(Map.merge(base, %{"note" => some("hi"), "score" => some(0)}))
        )

      {:ok, b} =
        Data.insert(
          repo,
          "Forum.Post",
          @v2,
          post(Map.merge(base, %{"note" => @none, "score" => @none}))
        )

      {:ok, {:rec, _, fa}} = Data.get(repo, "Forum.Post", @v2, a)
      {:ok, {:rec, _, fb}} = Data.get(repo, "Forum.Post", @v2, b)
      assert {fa["note"], fa["score"]} == {some("hi"), some(0)}
      assert {fb["note"], fb["score"]} == {@none, @none}

      assert sql!(repo, "SELECT note, score FROM forum__post ORDER BY _seq") == [
               ["hi", 0],
               [nil, nil]
             ]

      sql!(repo, "UPDATE forum__post SET pinned = NULL, tags = NULL, label = NULL")
      {:ok, {:rec, _, fa}} = Data.get(repo, "Forum.Post", @v2, a)
      assert {fa["pinned"], fa["tags"], fa["label"]} == {false, ["x"], "it's"}
    end

    test "NULL in a non-Option field without a default is a store error", %{dir: dir} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "Forum.Post", @v1, v1_post("t", 1))
      sql!(repo, "UPDATE forum__post SET votes = NULL")

      assert {:error, %{code: "store", message: message}} = Data.get(repo, "Forum.Post", @v1, id)
      assert message =~ "votes"
      assert {:error, %{code: "store"}} = Data.list(repo, "Forum.Post", @v1)
    end

    test "Bool is stored as 0/1 and Uuid as its canonical text", %{dir: dir} do
      repo = open!(dir)
      sig = [{"id", @uuid, :none}, {"on", @bool, :none}, {"ref", @uuid, :none}]
      ref = {:uuid, "22222222-2222-4222-8222-222222222222"}

      {:ok, id} =
        Data.insert(repo, "A.Flag", sig, {:rec, "A.Flag", %{"on" => true, "ref" => ref}})

      {:ok, _} =
        Data.insert(repo, "A.Flag", sig, {:rec, "A.Flag", %{"on" => false, "ref" => ref}})

      {:uuid, text} = id

      assert [[^text, 1, "22222222-2222-4222-8222-222222222222"], [_, 0, _]] =
               sql!(repo, ~s(SELECT id, "on", ref FROM a__flag ORDER BY _seq))

      sql!(repo, ~s(UPDATE a__flag SET "on" = 2))
      assert {:error, %{code: "store"}} = Data.list(repo, "A.Flag", sig)
    end
  end

  describe "compound values" do
    @models %{
      "Shop.Item" => [
        {"id", {:named, "Uuid"}, :none},
        {"nums", {:applied, "List", [{:named, "Int"}]}, :none},
        {"counts", {:applied, "Map", [{:named, "String"}, {:named, "Int"}]}, :none},
        {"pair", {:tuple, [{:named, "Int"}, {:named, "String"}]}, :none},
        {"addr", {:named, "Shop.Addr"}, :none},
        {"maybe", {:applied, "Option", [{:applied, "List", [{:named, "Int"}]}]}, :none},
        {"by_id", {:applied, "Map", [{:named, "Uuid"}, {:named, "Bool"}]}, :none}
      ],
      "Shop.Addr" => [
        {"street", {:named, "String"}, :none},
        {"zip", {:named, "Int"}, 0},
        {"unit", {:applied, "Option", [{:named, "String"}]}, :none}
      ]
    }

    defp item(maybe) do
      {:rec, "Shop.Item",
       %{
         "nums" => [1, -2, 3],
         "counts" => %{"a" => 1, "b" => 2},
         "pair" => {7, "seven"},
         "addr" => {:rec, "Shop.Addr", %{"street" => "Main", "zip" => 9, "unit" => some("4B")}},
         "maybe" => maybe,
         "by_id" => %{{:uuid, "33333333-3333-4333-8333-333333333333"} => true}
       }}
    end

    test "round-trip through JSON cells", %{dir: dir} do
      repo = open!(dir)

      for maybe <- [@none, some([]), some([5])] do
        {:rec, m, fields} = item(maybe)
        {:ok, id} = Data.insert(repo, "Shop.Item", @models, {:rec, m, fields})

        assert {:ok, {:rec, m, Map.put(fields, "id", id)}} ==
                 Data.get(repo, "Shop.Item", @models, id)
      end

      cols = columns(repo, "shop__item")
      assert Enum.all?(~w(nums counts pair addr maybe by_id), &(elem(cols[&1], 0) == "TEXT"))
    end

    test "a nested record missing a field takes its default", %{dir: dir} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "Shop.Item", @models, item(@none))
      sql!(repo, ~s(UPDATE shop__item SET addr = '{"street":"Old"}'))

      {:ok, {:rec, _, fields}} = Data.get(repo, "Shop.Item", @models, id)

      assert fields["addr"] ==
               {:rec, "Shop.Addr", %{"street" => "Old", "zip" => 0, "unit" => @none}}

      sql!(repo, ~s(UPDATE shop__item SET addr = '{"zip":1}'))
      assert {:error, %{code: "store", message: m}} = Data.get(repo, "Shop.Item", @models, id)
      assert m =~ "street"
    end

    test "a corrupt or mistyped JSON cell is a store error, never a crash", %{dir: dir} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "Shop.Item", @models, item(@none))

      for bad <- ["{not json", ~s(["a"]), "1.5", ~s({"$variant":"X.Y","values":[]})] do
        sql!(repo, "UPDATE shop__item SET nums = ?", [bad])
        assert {:error, %{code: "store", message: m}} = Data.get(repo, "Shop.Item", @models, id)
        assert m =~ "nums"
        assert {:error, %{code: "store"}} = Data.list(repo, "Shop.Item", @models)
      end
    end

    test "a value JSON cannot hold faithfully is refused on write", %{dir: dir} do
      repo = open!(dir)

      sig = [
        {"id", @uuid, :none},
        {"deep", option(option(@int)), :none},
        {"fns", list(@int), :none}
      ]

      row = {:rec, "A.Deep", %{"deep" => some(@none), "fns" => []}}
      assert {:error, %{code: "store"}} = Data.insert(repo, "A.Deep", sig, row)

      row = {:rec, "A.Deep", %{"deep" => @none, "fns" => [fn -> 1 end]}}
      assert {:error, %{code: "store"}} = Data.insert(repo, "A.Deep", sig, row)

      assert {:ok, []} = Data.list(repo, "A.Deep", sig)
    end
  end

  describe "names" do
    test "a model maps to its lowercased name with . as __", %{dir: dir} do
      repo = open!(dir)
      :ok = Data.ensure(repo, "Forum.Post", @v1)

      assert sql!(repo, "SELECT symbol, tbl FROM _kinoko_tables") == [
               ["Forum.Post", "forum__post"]
             ]
    end

    test "the fallback is m_ and 12 hex of the symbol's sha256" do
      hex =
        :crypto.hash(:sha256, "Forum.Post") |> Base.encode16(case: :lower) |> binary_part(0, 12)

      assert Kinoko.Data.Schema.fallback("Forum.Post") == "m_" <> hex
      assert Kinoko.Data.Schema.table_name("Forum.Post") == "forum__post"
      assert Kinoko.Data.Schema.table_name("Für.Post") == Kinoko.Data.Schema.fallback("Für.Post")

      assert Kinoko.Data.Schema.column_name("createdAt") ==
               Kinoko.Data.Schema.fallback("createdAt")

      assert Kinoko.Data.Schema.column_name("created_at") == "created_at"
    end

    test "a colliding or reserved table name falls back, recorded", %{dir: dir} do
      repo = open!(dir)
      :ok = Data.ensure(repo, "Forum.Post", @v1)
      :ok = Data.ensure(repo, "Forum.POST", @v1)
      :ok = Data.ensure(repo, "Sqlite.Thing", @v1)

      tables = Map.new(sql!(repo, "SELECT symbol, tbl FROM _kinoko_tables"), &List.to_tuple/1)
      assert tables["Forum.Post"] == "forum__post"
      assert tables["Forum.POST"] == Kinoko.Data.Schema.fallback("Forum.POST")
      assert tables["Sqlite.Thing"] == Kinoko.Data.Schema.fallback("Sqlite.Thing")

      {:ok, _} =
        Data.insert(
          repo,
          "Forum.POST",
          @v1,
          {:rec, "Forum.POST", %{"title" => "x", "votes" => 1}}
        )

      assert {:ok, []} = Data.list(repo, "Forum.Post", @v1)
      assert {:ok, [{:rec, "Forum.POST", _}]} = Data.list(repo, "Forum.POST", @v1)
    end

    test "a field outside [a-z0-9_] gets a hashed column, recorded", %{dir: dir} do
      repo = open!(dir)
      sig = [{"id", @uuid, :none}, {"createdAt", @int, :none}, {"_seq", @int, :none}]
      {:ok, id} = Data.insert(repo, "A.Ev", sig, {:rec, "A.Ev", %{"createdAt" => 5, "_seq" => 9}})

      cols =
        Map.new(
          sql!(repo, "SELECT field, col FROM _kinoko_columns WHERE tbl = 'a__ev'"),
          &List.to_tuple/1
        )

      assert cols["createdAt"] == Kinoko.Data.Schema.fallback("createdAt")
      assert cols["_seq"] == Kinoko.Data.Schema.fallback("_seq")
      assert Map.has_key?(columns(repo, "a__ev"), cols["createdAt"])

      assert {:ok, {:rec, "A.Ev", %{"id" => id, "createdAt" => 5, "_seq" => 9}}} ==
               Data.get(repo, "A.Ev", sig, id)
    end
  end

  describe "list cap" do
    test "is 10_000 by default" do
      assert Data.max_rows() == 10_000
    end

    test "above the cap is too-many-rows, at it the rows", %{dir: dir} do
      repo = open!(dir)
      for i <- 1..3, do: {:ok, _} = Data.insert(repo, "Forum.Post", @v1, v1_post("p", i))
      assert {:ok, rows} = Data.list(repo, "Forum.Post", @v1, cap: 3)
      assert length(rows) == 3

      {:ok, _} = Data.insert(repo, "Forum.Post", @v1, v1_post("p", 4))

      assert {:error, %{code: "too-many-rows", message: m}} =
               Data.list(repo, "Forum.Post", @v1, cap: 3)

      assert m =~ "3"
    end
  end

  describe "transactions" do
    test "a first insert in a rolled-back transaction leaves no stale schema", %{dir: dir} do
      repo = open!(dir)

      assert {:error, :undo} =
               Data.transaction(repo, fn ->
                 {:ok, _} = Data.insert(repo, "Forum.Post", @v1, v1_post("t", 1))
                 Data.rollback(:undo)
               end)

      assert [] == sql!(repo, "SELECT name FROM sqlite_master WHERE name = 'forum__post'")
      assert {:ok, _} = Data.insert(repo, "Forum.Post", @v1, v1_post("t", 1))
      assert {:ok, [_]} = Data.list(repo, "Forum.Post", @v1)
    end

    test "an evolution in a rolled-back transaction leaves no stale schema", %{dir: dir} do
      repo = open!(dir)
      {:ok, id} = Data.insert(repo, "Forum.Post", @v1, v1_post("t", 1))

      assert {:error, :undo} =
               Data.transaction(repo, fn ->
                 :ok = Data.ensure(repo, "Forum.Post", @v2)
                 Data.rollback(:undo)
               end)

      refute Map.has_key?(columns(repo, "forum__post"), "pinned")

      assert {:ok, [{:rec, _, %{"id" => ^id, "pinned" => false}}]} =
               Data.list(repo, "Forum.Post", @v2)

      assert Map.has_key?(columns(repo, "forum__post"), "pinned")
    end

    test "a committed transaction keeps its writes", %{dir: dir} do
      repo = open!(dir)

      assert {:ok, {:uuid, _} = id} =
               Data.transaction(repo, fn ->
                 {:ok, id} = Data.insert(repo, "Forum.Post", @v1, v1_post("t", 1))
                 id
               end)

      assert {:ok, {:rec, _, %{"id" => ^id}}} = Data.get(repo, "Forum.Post", @v1, id)
    end
  end

  describe "errors" do
    test "a closed deployment's repo is unavailable", %{dir: dir} do
      repo = open!(dir)
      :ok = Data.close("app", dir: dir)
      assert {:error, %{code: "unavailable"}} = Data.list(repo, "Forum.Post", @v1)

      assert {:error, %{code: "unavailable"}} =
               Data.insert(repo, "Forum.Post", @v1, v1_post("t", 1))
    end

    test "a locked file is unavailable, not a store error", %{dir: dir} do
      {:ok, repo} = Data.open("app", dir: dir, busy_timeout: 50)
      :ok = Data.ensure(repo, "Forum.Post", @v1)

      {:ok, conn} = Exqlite.Sqlite3.open(Path.join([dir, "data", "app.db"]))
      :ok = Exqlite.Sqlite3.execute(conn, "BEGIN IMMEDIATE")

      try do
        assert {:error, %{code: "unavailable"}} =
                 Data.insert(repo, "Forum.Post", @v1, v1_post("t", 1))
      after
        :ok = Exqlite.Sqlite3.execute(conn, "ROLLBACK")
        Exqlite.Sqlite3.close(conn)
      end

      assert {:ok, _} = Data.insert(repo, "Forum.Post", @v1, v1_post("t", 1))
    end

    test "a busy file is waited for, then written", %{dir: dir} do
      repo = open!(dir)
      :ok = Data.ensure(repo, "Forum.Post", @v1)

      {:ok, conn} = Exqlite.Sqlite3.open(Path.join([dir, "data", "app.db"]))
      :ok = Exqlite.Sqlite3.execute(conn, "BEGIN IMMEDIATE")

      holder =
        Task.async(fn ->
          Process.sleep(500)
          :ok = Exqlite.Sqlite3.execute(conn, "ROLLBACK")
          Exqlite.Sqlite3.close(conn)
        end)

      started = System.monotonic_time(:millisecond)
      assert {:ok, _} = Data.insert(repo, "Forum.Post", @v1, v1_post("t", 1))
      assert System.monotonic_time(:millisecond) - started >= 300
      Task.await(holder)
      assert {:ok, [_]} = Data.list(repo, "Forum.Post", @v1)
    end

    test "a row of the wrong shape is a store error", %{dir: dir} do
      repo = open!(dir)

      assert {:error, %{code: "store"}} =
               Data.insert(repo, "Forum.Post", @v1, post(%{"title" => "t"}))

      assert {:error, %{code: "store"}} =
               Data.insert(repo, "Forum.Post", @v1, post(%{"title" => 1, "votes" => 1}))
    end

    test "an operation whose model never settled is refused before any SQL", %{dir: dir} do
      repo = open!(dir)

      for result <- [
            Data.insert(repo, nil, @v1, v1_post("t", 1)),
            Data.list(repo, nil, %{"Forum.Post" => @v1}),
            Data.get(repo, nil, @v1, {:uuid, Ecto.UUID.generate()})
          ] do
        assert {:error, %{code: "store", message: message}} = result
        assert message =~ "never settled"
      end

      assert sql!(repo, "SELECT COUNT(*) FROM _kinoko_tables") == [[0]]
    end
  end

  describe "stats" do
    test "lists each model's table, row count and columns", %{dir: dir} do
      assert Data.stats("app", dir: dir) == []
      repo = open!(dir)
      {:ok, _} = Data.insert(repo, "Forum.Post", @v1, v1_post("a", 1))
      {:ok, _} = Data.insert(repo, "Forum.Post", @v1, v1_post("b", 2))
      :ok = Data.ensure(repo, "A.Empty", [{"id", @uuid, :none}])

      assert [empty, posts] = Data.stats("app", dir: dir)
      assert %{model: "A.Empty", table: "a__empty", rows: 0} = empty
      assert %{model: "Forum.Post", table: "forum__post", rows: 2, columns: columns} = posts

      assert Enum.map(columns, & &1.name) == ~w(id _seq title votes)
      assert %{name: "votes", field: "votes", type: "INTEGER"} = List.last(columns)
    end

    test "of a deployment with no file is empty and makes none", %{dir: dir} do
      assert Data.stats("nothing", dir: dir) == []
      refute File.exists?(Path.join([dir, "data", "nothing.db"]))
    end
  end
end
