defmodule Kinoko.CodeDbEncodingTest do
  # A universe stored by one VM must boot in a fresh one. `binary_to_term`
  # with `:safe` refuses atoms the decoding node has not loaded yet, and in
  # dev modules load lazily, so CodeDb's stored binary holds no atom at all.
  use ExUnit.Case, async: true

  alias Kinoko.CodeDb

  defp atoms(term) do
    case term do
      t when is_atom(t) -> [t]
      t when is_list(t) -> Enum.flat_map(t, &atoms/1)
      t when is_tuple(t) -> t |> Tuple.to_list() |> Enum.flat_map(&atoms/1)
      t when is_map(t) -> Enum.flat_map(t, fn {k, v} -> atoms(k) ++ atoms(v) end)
      _ -> []
    end
  end

  defp string, do: for(_ <- 1..:rand.uniform(6), into: "", do: <<Enum.random(?a..?z)>>)
  defp cid, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  defp some(f), do: for(_ <- 0..Enum.random(0..4)//1, do: f.()) |> Enum.drop(1)

  defp random_durable do
    commits =
      some(fn ->
        %{
          ids: some(&string/0),
          entries:
            some(fn ->
              Enum.random([{:live, string(), cid()}, {:gone, string()}])
            end)
        }
      end)

    staged =
      some(fn -> {string(), some(fn -> {string(), Enum.random([cid(), :gone])} end)} end)

    %{commits: commits, staged: staged}
  end

  test "an encoded durable holds no atom and reads back as itself" do
    for _ <- 1..300 do
      durable = random_durable()
      binary = CodeDb.encode(durable)
      assert atoms(:erlang.binary_to_term(binary)) == []
      assert CodeDb.stored(binary) == durable
    end
  end

  test "a version-1 binary (the durable map itself) still reads" do
    durable = %{
      commits: [%{ids: ["p1"], entries: [{:live, "A.g", cid()}, {:gone, "A.h"}]}],
      staged: [{"p2", [{"A.f", cid()}, {"A.g", :gone}]}]
    }

    assert CodeDb.stored(:erlang.term_to_binary(durable)) == durable
    assert CodeDb.version() == 2
    assert CodeDb.migrate(:state, 1) == :state
  end

  @src "def A.g() : Int do\n  1\nend"

  # Writes a universe from one VM into a temp SQLite file, then boots it in
  # another: a plain `elixir` (interactive code loading, as in dev) where
  # nothing but what the decode itself touches is loaded.
  @tag :tmp_dir
  test "a universe written by one VM decodes in a fresh VM", %{tmp_dir: dir} do
    db = Path.join(dir, "kinoko.db")
    v1 = Path.join(dir, "v1.bin")
    v2 = Path.join(dir, "v2.bin")
    migrations = Path.expand("priv/repo/migrations", File.cwd!())

    boot = """
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Kinoko.Repo.start_link(database: #{inspect(db)}, pool_size: 1, log: false)
    """

    write =
      boot <>
        """
        Ecto.Migrator.run(Kinoko.Repo, #{inspect(migrations)}, :up, all: true, log: false)
        {:ok, _entries, texts} = Kinoko.Lang.prepare(#{inspect(@src)})
        :ok = Kinoko.Cas.put(texts)
        {u, {:promoted, _}} = Kinoko.Lang.stage(Kinoko.Lang.new(), "p1", #{inspect(@src)})
        durable = Kinoko.Lang.durable(u)
        v2 = Kinoko.CodeDb.encode(durable)
        :ok = Kinoko.Elm.Store.append(Kinoko.CodeDb.key("main"), 0, "Kinoko.CodeDb",
          Kinoko.CodeDb.version(), v2)
        File.write!(#{inspect(v2)}, v2)
        File.write!(#{inspect(v1)}, :erlang.term_to_binary(durable))
        """

    # Before anything loads: the version-1 binary is refused (the bug), the
    # stored one is not. A script of its own: evaluating one expands it
    # whole first, which loads every module it names (and their atoms).
    bare = """
    safe = fn b -> try do {:ok, :erlang.binary_to_term(b, [:safe])} rescue e -> {:error, e} end end
    {:error, %ArgumentError{}} = safe.(File.read!(#{inspect(v1)}))
    {:ok, _} = safe.(File.read!(#{inspect(v2)}))
    """

    read =
      boot <>
        """
        false = :code.is_loaded(Kinoko.Lang.Universe)
        {:ok, row} = Kinoko.Elm.Store.latest(Kinoko.CodeDb.key("main"))
        state = Kinoko.CodeDb.decode(row.state)
        [_] = Kinoko.CodeDb.stored(File.read!(#{inspect(v1)})).commits
        IO.write(Enum.map_join(Kinoko.Lang.symbols(state.u), ",", & &1.name))
        """

    assert {_, 0} = run(write)
    assert {"A.g", 0} = run([bare, read])
  end

  # Canonical text an older parser stored (JSX text kept its inner
  # newline): a fresh VM boots it healthy under the CID it was stored with.
  @tag :tmp_dir
  test "text stored in an older canonical shape boots in a fresh VM under its CID", %{
    tmp_dir: dir
  } do
    db = Path.join(dir, "kinoko.db")
    migrations = Path.expand("priv/repo/migrations", File.cwd!())
    view = "def A.v() : Html<A.Msg> do\n  <p>\n    one\n    two\n  </p>\nend"
    cid = :crypto.hash(:sha256, ["yabu/1\n", view]) |> Base.encode16(case: :lower)

    boot = """
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Kinoko.Repo.start_link(database: #{inspect(db)}, pool_size: 1, log: false)
    """

    write =
      boot <>
        """
        Ecto.Migrator.run(Kinoko.Repo, #{inspect(migrations)}, :up, all: true, log: false)
        {:ok, _, [{msg, _}] = texts} = Kinoko.Lang.prepare("deftype A.Msg do\\n  Go\\nend")
        :ok = Kinoko.Cas.put([{#{inspect(cid)}, #{inspect(view)}} | texts])
        durable = %{commits: [%{ids: ["old"], entries: [{:live, "A.Msg", msg}, {:live, "A.v", #{inspect(cid)}}]}], staged: []}
        :ok = Kinoko.Elm.Store.append(Kinoko.CodeDb.key("main"), 0, "Kinoko.CodeDb",
          Kinoko.CodeDb.version(), Kinoko.CodeDb.encode(durable))
        """

    read =
      boot <>
        """
        {:ok, row} = Kinoko.Elm.Store.latest(Kinoko.CodeDb.key("main"))
        state = Kinoko.CodeDb.decode(row.state)
        :ok = Kinoko.Lang.health(state.u)
        IO.write(Enum.find(Kinoko.Lang.symbols(state.u), &(&1.name == "A.v")).cid)
        """

    assert {_, 0} = run(write)
    assert {^cid, 0} = run(read)
  end

  # Each script is its own `-e`, evaluated in order in one VM.
  defp run(scripts) do
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ Enum.flat_map(List.wrap(scripts), &["-e", &1])
    System.cmd("elixir", args, stderr_to_stdout: true)
  end
end
