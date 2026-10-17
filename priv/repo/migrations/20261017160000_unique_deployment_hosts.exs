defmodule Kinoko.Repo.Migrations.UniqueDeploymentHosts do
  use Ecto.Migration

  # Hosts were not checked before: a deployment could list localhost (and
  # take `/` from `local`) or another's `<name>.localhost`. Drop such rows
  # (Kinoko.Deployment.repair_hosts/1), then make each host one deployment's.
  def up do
    Kinoko.Deployment.repair_hosts(repo())
    drop index(:deployment_hosts, [:host])
    create unique_index(:deployment_hosts, [:host])
  end

  def down do
    drop index(:deployment_hosts, [:host])
    create index(:deployment_hosts, [:host])
  end
end
