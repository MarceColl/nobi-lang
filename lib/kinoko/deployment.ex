defmodule Kinoko.Deployment do
  @moduledoc """
  The `deployments` table: a named, served view of a universe.

  A deployment is `%{name, universe, routes, commit, hosts}`. `routes` names
  the route table (a `defroutes` symbol) the host serves; `commit` is `nil`
  to follow the universe's head, or a 1-based history position it is pinned
  to; `hosts` are the exact hostnames that reach it. Where
  `:localhost_deployments` is on (it defaults to `:mcp_enabled`: dev,
  test and the local `kinoko` build, never a server build), a host `<name>.localhost` reaches deployment `<name>`
  without being listed.

  `pin/2` and `follow/1` announce the change on `Kinoko.PubSub`, topic
  `topic(name)`, as `{:deployment_changed, name}`, so pages serving the
  deployment switch code at once.

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
  Creates a deployment. Options: `commit:` (default `nil`, follow head; a
  commit is checked like `pin/2`'s, anything else is `{:error,
  :no_such_commit}`) and `hosts:` (default `[]`, a list of strings).
  Non-string name, universe, routes or hosts are `{:error, :bad_name}`.
  """
  @spec create(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :exists | :bad_name | :no_such_universe | :no_such_commit | term()}
  def create(name, universe, routes, opts \\ []) do
    commit = Keyword.get(opts, :commit)
    hosts = Keyword.get(opts, :hosts, [])

    cond do
      not Registry.valid_name?(name) or not is_binary(universe) or not is_binary(routes) or
          not (is_list(hosts) and Enum.all?(hosts, &is_binary/1)) ->
        {:error, :bad_name}

      not universe_exists?(universe) ->
        {:error, :no_such_universe}

      commit != nil and check_commit(universe, commit) != :ok ->
        check_commit(universe, commit)

      true ->
        insert(
          name,
          universe,
          routes,
          commit,
          hosts |> Enum.map(&normalize_host/1) |> Enum.uniq()
        )
    end
  end

  # The deployment row and its hosts are written in one transaction, so a
  # deployment is never seen without its hosts.
  defp insert(name, universe, routes, commit, hosts) do
    now = DateTime.utc_now()

    row = %{
      name: name,
      universe: universe,
      routes: routes,
      commit: commit,
      inserted_at: now,
      updated_at: now
    }

    Repo.transaction(fn ->
      case Repo.insert_all("deployments", [row], on_conflict: :nothing, conflict_target: :name) do
        {1, _} ->
          # 3 bound parameters per row; chunks stay under SQLite's limit (32_766).
          hosts
          |> Enum.with_index()
          |> Enum.map(fn {host, i} -> %{deployment: name, host: host, position: i} end)
          |> Enum.chunk_every(10_000)
          |> Enum.each(&Repo.insert_all("deployment_hosts", &1))

          :ok

        {0, _} ->
          Repo.rollback(:exists)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, :exists} -> {:error, :exists}
    end
  end

  @spec get(String.t()) :: {:ok, t} | :error
  def get(name) when is_binary(name) do
    case fetch_all(from(d in "deployments", where: d.name == ^name)) do
      [] -> :error
      [d] -> {:ok, d}
    end
  end

  def get(_), do: :error

  @spec list() :: [t]
  def list, do: fetch_all(from(d in "deployments", order_by: d.name))

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
  The `Kinoko.PubSub` topic on which `pin/2` and `follow/1` broadcast
  `{:deployment_changed, name}` after the row is written. Pure.
  """
  @spec topic(String.t()) :: String.t()
  def topic(name) when is_binary(name), do: "deployment:" <> name

  @doc """
  The deployment a request host reaches: an exact match against any
  deployment's `hosts`, else, where `:localhost_deployments` is configured
  (dev and test only), `<name>.localhost` for deployment `<name>`.
  Case-insensitive; a port and a trailing dot are ignored.
  """
  @spec resolve(String.t()) :: {:ok, t} | :error
  def resolve(host) when is_binary(host) do
    host = normalize_host(host)

    # An indexed lookup on deployment_hosts.host.
    query =
      from d in "deployments",
        join: h in "deployment_hosts",
        on: h.deployment == d.name,
        where: h.host == ^host,
        order_by: d.name,
        limit: 1

    case fetch_all(query) do
      [] -> by_localhost(host)
      [d] -> {:ok, d}
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

  @doc """
  Idempotently creates `main` and then `local` (universe `main`, routes `Main`,
  following head, hosts `localhost` and `127.0.0.1`). It does not repair an
  existing `local` row that has since been changed.
  """
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
    case {localhost_deployments?(), String.split(host, ".")} do
      {true, [name, "localhost"]} -> get(name)
      _ -> :error
    end
  end

  # `:localhost_deployments`; unset, it follows `:mcp_enabled`, which is
  # set in dev, test and the local build (never a server build), like deployment serving itself.
  defp localhost_deployments? do
    Application.get_env(
      :kinoko,
      :localhost_deployments,
      Application.get_env(:kinoko, :mcp_enabled, false)
    ) == true
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

    Phoenix.PubSub.broadcast(Kinoko.PubSub, topic(name), {:deployment_changed, name})
  end

  defp universe_exists?(universe) do
    case Universe.list() do
      list when is_list(list) -> Enum.any?(list, &(&1.name == universe))
      _ -> false
    end
  end

  # Hosts compare lowercase, without a port and without a trailing dot
  # (`App.Example.com.:4000` is `app.example.com`).
  defp normalize_host(host) do
    host |> String.downcase() |> String.replace(~r/:\d+$/, "") |> String.trim_trailing(".")
  end

  # The deployments `query` selects, each with its hosts in their given order.
  defp fetch_all(query) do
    deployments =
      Repo.all(
        from d in query,
          select: %{name: d.name, universe: d.universe, routes: d.routes, commit: d.commit}
      )

    hosts = hosts_of(Enum.map(deployments, & &1.name))
    Enum.map(deployments, &Map.put(&1, :hosts, Map.get(hosts, &1.name, [])))
  end

  # `%{deployment => [host]}`. Names are chunked to stay well under
  # SQLite's bound-parameter limit.
  defp hosts_of([]), do: %{}

  defp hosts_of(names) do
    names
    |> Enum.chunk_every(10_000)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from h in "deployment_hosts",
          where: h.deployment in ^chunk,
          order_by: [h.deployment, h.position],
          select: {h.deployment, h.host}
      )
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end
end
