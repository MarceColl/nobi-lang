defmodule Kinoko.Universe.Registry do
  @moduledoc """
  The `universes` table: which universes exist and where they were forked from.

  Process-free; plain functions over `Kinoko.Repo`. `ensure_main/0` is run at
  boot by a one-shot task (see `Kinoko.Application`).
  """

  import Ecto.Query

  alias Kinoko.Repo

  @name ~r/^[a-z0-9][a-z0-9_-]{0,62}$/

  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @spec create(String.t(), keyword()) :: :ok | {:error, :exists | :bad_name}
  def create(name, opts \\ []) do
    if valid_name?(name) do
      row = %{
        name: name,
        parent: Keyword.get(opts, :parent),
        forked_at_commit: Keyword.get(opts, :forked_at_commit),
        created_at: DateTime.utc_now()
      }

      case Repo.insert_all("universes", [row], on_conflict: :nothing, conflict_target: :name) do
        {1, _} -> :ok
        {0, _} -> {:error, :exists}
      end
    else
      {:error, :bad_name}
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(name) when is_binary(name) do
    Repo.exists?(from u in "universes", where: u.name == ^name)
  end

  def exists?(_), do: false

  @spec list() :: [
          %{
            name: String.t(),
            parent: String.t() | nil,
            forked_at_commit: integer() | nil,
            created_at: DateTime.t()
          }
        ]
  def list do
    Repo.all(
      from u in "universes",
        order_by: u.name,
        select: %{
          name: u.name,
          parent: u.parent,
          forked_at_commit: u.forked_at_commit,
          created_at: u.created_at
        }
    )
  end

  @doc "Idempotently creates `main`."
  @spec ensure_main() :: :ok
  def ensure_main do
    case create("main") do
      :ok -> :ok
      {:error, :exists} -> :ok
    end
  end

  @doc false
  # Boot hook: never raises, so a DB outage cannot take the app down. The first
  # Universe call is expected to retry `ensure_main/0`.
  def ensure_main_at_boot do
    ensure_main()
  rescue
    e ->
      require Logger
      Logger.error("Universe.Registry.ensure_main failed at boot: #{Exception.message(e)}")
  catch
    kind, reason ->
      require Logger
      Logger.error("Universe.Registry.ensure_main failed at boot: #{inspect({kind, reason})}")
  end
end
