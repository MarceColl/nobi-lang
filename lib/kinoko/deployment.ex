defmodule Kinoko.Deployment do
  @moduledoc """
  The `deployments` table: a named, served view of a universe.

  A deployment is `%{name, universe, routes, commit, hosts}`. `routes` names
  the route table (a `defroutes` symbol) the host serves; `commit` is `nil`
  to follow the universe's head, or a 1-based history position it is pinned
  to; `hosts` are the exact hostnames that reach it. A host
  `<name>.localhost` reaches deployment `<name>` without being listed.

  Process-free; plain functions over `Kinoko.Repo`. Universes are only ever
  reached through `Kinoko.Universe`. `ensure_local/0` runs at boot (see
  `Kinoko.Application`).
  """

  import Ecto.Query

  alias Kinoko.{Repo, Universe}
  alias Kinoko.Universe.Registry

  @type t :: %{
          name: String.t(),
          universe: String.t(),
          routes: String.t(),
          commit: pos_integer() | nil,
          hosts: [String.t()]
        }

  @doc """
  Creates a deployment. Options: `commit:` (default `nil`, follow head) and
  `hosts:` (default `[]`). A commit given here is not checked; use `pin/2`
  to pin with validation.
  """
  @spec create(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :exists | :bad_name | :no_such_universe}
  def create(name, universe, routes, opts \\ []) do
    cond do
      not Registry.valid_name?(name) ->
        {:error, :bad_name}

      not universe_exists?(universe) ->
        {:error, :no_such_universe}

      true ->
        now = DateTime.utc_now()

        row = %{
          name: name,
          universe: universe,
          routes: routes,
          commit: Keyword.get(opts, :commit),
          hosts: opts |> Keyword.get(:hosts, []) |> Enum.map(&normalize_host/1),
          inserted_at: now,
          updated_at: now
        }

        case Repo.insert_all("deployments", [row], on_conflict: :nothing, conflict_target: :name) do
          {1, _} -> :ok
          {0, _} -> {:error, :exists}
        end
    end
  end

  @spec get(String.t()) :: {:ok, t} | :error
  def get(name) when is_binary(name) do
    case Repo.one(select_fields(from(d in "deployments", where: d.name == ^name))) do
      nil -> :error
      d -> {:ok, d}
    end
  end

  def get(_), do: :error

  @spec list() :: [t]
  def list, do: Repo.all(select_fields(from(d in "deployments", order_by: d.name)))

  @doc """
  Pins the deployment to `commit`, a 1-based position in its universe's
  history: `{:error, :not_found}` for an unknown deployment,
  `{:error, :no_such_commit}` for a commit outside that history.
  """
  @spec pin(String.t(), term()) :: :ok | {:error, :not_found | :no_such_commit | term()}
  def pin(name, commit) do
    with {:ok, d} <- fetch(name),
         :ok <- check_commit(d.universe, commit) do
      set_commit(name, commit)
    end
  end

  @doc "Makes the deployment follow its universe's head again."
  @spec follow(String.t()) :: :ok | {:error, :not_found}
  def follow(name) do
    with {:ok, _} <- fetch(name), do: set_commit(name, nil)
  end

  @doc """
  The deployment a request host reaches: an exact match against any
  deployment's `hosts`, else `<name>.localhost` for deployment `<name>`.
  Case-insensitive; a port is ignored.
  """
  @spec resolve(String.t()) :: {:ok, t} | :error
  def resolve(host) when is_binary(host) do
    host = normalize_host(host)

    case Repo.one(
           select_fields(
             from(d in "deployments", where: ^host in d.hosts, order_by: d.name, limit: 1)
           )
         ) do
      nil -> by_localhost(host)
      d -> {:ok, d}
    end
  end

  def resolve(_), do: :error

  @doc """
  What to run for a deployment: `{:ok, universe_name}` when it follows head,
  or `Kinoko.Universe.at/2`'s handle (or its error) when pinned.
  """
  @spec target(t) :: {:ok, String.t() | Universe.At.t()} | {:error, term()}
  def target(%{commit: nil, universe: universe}), do: {:ok, universe}
  def target(%{commit: commit, universe: universe}), do: Universe.at(universe, commit)

  @local_hosts ["localhost", "127.0.0.1"]

  @doc "Idempotently creates `local` (and `main`, which it serves): universe `main`, routes `Main`, following head."
  @spec ensure_local() :: :ok
  def ensure_local do
    :ok = Registry.ensure_main()

    case create("local", "main", "Main", hosts: @local_hosts) do
      :ok -> :ok
      {:error, :exists} -> :ok
    end
  end

  @doc false
  # Boot hook; never raises, like `Registry.ensure_main_at_boot/0`.
  def ensure_local_at_boot do
    ensure_local()
  rescue
    e ->
      require Logger
      Logger.error("Deployment.ensure_local failed at boot: #{Exception.message(e)}")
  catch
    kind, reason ->
      require Logger
      Logger.error("Deployment.ensure_local failed at boot: #{inspect({kind, reason})}")
  end

  defp by_localhost(host) do
    case String.split(host, ".") do
      [name, "localhost"] -> get(name)
      _ -> :error
    end
  end

  defp fetch(name) do
    case get(name) do
      {:ok, d} -> {:ok, d}
      :error -> {:error, :not_found}
    end
  end

  defp check_commit(universe, commit) do
    case Universe.history(universe) do
      history
      when is_list(history) and is_integer(commit) and commit >= 1 and
             commit <= length(history) ->
        :ok

      history when is_list(history) ->
        {:error, :no_such_commit}

      {:error, _} = error ->
        error
    end
  end

  defp set_commit(name, commit) do
    {1, _} =
      Repo.update_all(from(d in "deployments", where: d.name == ^name),
        set: [commit: commit, updated_at: DateTime.utc_now()]
      )

    :ok
  end

  defp universe_exists?(universe) do
    case Universe.list() do
      list when is_list(list) -> Enum.any?(list, &(&1.name == universe))
      _ -> false
    end
  end

  # Hosts compare lowercase and without a port.
  defp normalize_host(host) do
    host |> String.downcase() |> String.replace(~r/:\d+$/, "")
  end

  defp select_fields(query) do
    from d in query,
      select: %{
        name: d.name,
        universe: d.universe,
        routes: d.routes,
        commit: d.commit,
        hosts: d.hosts
      }
  end
end
