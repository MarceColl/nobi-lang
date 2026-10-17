defmodule Kinoko.Repo.Migrations.UniqueDeploymentHosts do
  use Ecto.Migration

  # Hosts were not checked before: a deployment could list localhost (and
  # take `/` from `local`) or another's `<name>.localhost`. Drop such rows,
  # then make each host one deployment's. Self-contained: it must mean the
  # same whatever Kinoko.Deployment becomes.
  def up do
    repair(repo())
    drop index(:deployment_hosts, [:host])
    create unique_index(:deployment_hosts, [:host])
  end

  def down do
    drop index(:deployment_hosts, [:host])
    create index(:deployment_hosts, [:host])
  end

  @doc false
  # Deletes loopback hosts (localhost, ::1, 0.0.0.0, 127.0.0.0/8) on any
  # deployment but `local`, any `*.localhost` but the deployment's own, and
  # every second claim of a host (the first by deployment name stays, the
  # one resolve served). Returns how many rows went. Public for its test.
  def repair(repo) do
    [
      """
      DELETE FROM deployment_hosts
      WHERE deployment <> 'local'
        AND (host IN ('localhost', '127.0.0.1', '[::1]', '::1', '0.0.0.0')
             OR (host GLOB '127.*' AND host NOT GLOB '*[^0-9.]*'))
      """,
      """
      DELETE FROM deployment_hosts
      WHERE host LIKE '%.localhost' AND host <> deployment || '.localhost'
      """,
      """
      DELETE FROM deployment_hosts
      WHERE EXISTS (
        SELECT 1 FROM deployment_hosts o
        WHERE o.host = deployment_hosts.host
          AND (o.deployment < deployment_hosts.deployment
               OR (o.deployment = deployment_hosts.deployment
                   AND o.position < deployment_hosts.position)))
      """
    ]
    |> Enum.map(&repo.query!(&1).num_rows)
    |> Enum.sum()
  end
end
