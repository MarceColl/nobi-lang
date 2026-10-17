defmodule Kinoko.UniverseHelpers do
  @moduledoc """
  Test helpers for `Kinoko.Universe` and `Kinoko.CodeDb`: a fresh universe
  per test whose CodeDb is stopped on exit, and access to its stored rows.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Kinoko.PersistentElmGenServer, as: Server

  @doc "Creates a uniquely named universe and stops its CodeDb on exit."
  def fresh_universe(prefix \\ "t") do
    name = "#{prefix}-#{System.unique_integer([:positive])}"
    :ok = Kinoko.Universe.create(name)
    stop_on_exit(name)
    name
  end

  @doc """
  Points `Kinoko.Data` at `dir` (a test's `tmp_dir`) for this test: every
  deployment's file opened without an explicit `dir:` lands there. On
  exit the files opened under `dir` are closed and the previous setting
  restored. For sync tests only (it changes the application env).
  """
  def isolated_data(dir) do
    previous = Application.fetch_env(:kinoko, Kinoko.Data)
    Application.put_env(:kinoko, Kinoko.Data, dir: dir)

    on_exit(fn ->
      for path <- Registry.select(Kinoko.Data.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]),
          is_binary(path) and String.starts_with?(path, dir),
          do: Kinoko.Data.Opener.close(path)

      case previous do
        {:ok, value} -> Application.put_env(:kinoko, Kinoko.Data, value)
        :error -> Application.delete_env(:kinoko, Kinoko.Data)
      end
    end)

    :ok
  end

  @doc """
  Stops, when the test exits, every universe's CodeDb running then: any
  key under `"universe:"` in `Kinoko.Elm.Registry`, whoever started it (a
  test that reaches `"main"` through a default argument included). Run for
  every sync `Kinoko.DataCase` / `KinokoWeb.ConnCase` test; it runs before
  the sandbox owner stops, so no CodeDb outlives its test's data.
  """
  def stop_universes_on_exit, do: on_exit(&stop_all/0)

  @doc "Stops every running universe's CodeDb for good."
  def stop_all do
    for {key, pid} <- running(), String.starts_with?(key, "universe:") do
      DynamicSupervisor.terminate_child(Kinoko.Elm.Supervisor, pid)
    end

    :ok
  end

  defp running,
    do: Registry.select(Kinoko.Elm.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

  @doc "Stops the CodeDb of `name` (if running) when the test exits."
  def stop_on_exit(name), do: on_exit(fn -> stop(name) end)

  @doc "Stops the CodeDb of `name` for good (no supervisor restart)."
  def stop(name) do
    case Server.whereis(key(name)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Kinoko.Elm.Supervisor, pid)
    end

    :ok
  end

  def key(name), do: "universe:" <> name

  def pid(name), do: Server.whereis(key(name))

  @doc """
  Stores `source` as universe `name`'s only commit (id `"old"`), written
  directly to the CAS and to the CodeDb's row, without checking it: what
  storage holds after the checker changed under code that used to
  typecheck. Stop the universe first if it runs.
  """
  def store_commit(name, source), do: store_commits(name, [{"old", source}])

  @doc """
  As `store_commit/2`, one commit per `{id, source}`, oldest first: each
  commit's entries are the declarations its source defines.
  """
  def store_commits(name, commits) do
    alias Kinoko.{Cas, CodeDb, Lang}

    commits =
      for {id, source} <- commits do
        {:ok, entries, texts} = Lang.prepare(source)
        :ok = Cas.put(texts)

        live =
          for {{:live, decl}, {cid, _}} <- Enum.zip(entries, texts),
              do: {:live, Kinoko.Lang.Ast.name(decl), cid}

        %{ids: [id], entries: live}
      end

    store_durable(name, %{commits: commits, staged: []})
  end

  @doc """
  Appends `durable` (as `Kinoko.Lang.durable/1` gives it) as `name`'s
  newest CodeDb row, as if a CodeDb had stored it; its CIDs must be in the
  CAS already.
  """
  def store_durable(name, durable) do
    alias Kinoko.CodeDb

    seq =
      case Kinoko.Elm.Store.latest(key(name)) do
        :none -> 0
        {:ok, row} -> row.seq + 1
      end

    :ok =
      Kinoko.Elm.Store.append(
        key(name),
        seq,
        inspect(CodeDb),
        CodeDb.version(),
        CodeDb.encode(durable)
      )
  end

  @doc "Every stored row of `name`'s CodeDb, newest first."
  def rows(name), do: Kinoko.Elm.Store.history(key(name), 1_000)
end
