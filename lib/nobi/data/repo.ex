defmodule Nobi.Data.Repo do
  @moduledoc """
  The repo of a deployment's own SQLite file (`Nobi.Data`).

  Never started by name and never in `ecto_repos`: `Nobi.Data.Opener`
  starts one anonymous instance per file (`start_link(name: nil, database:
  path)`), and every `Nobi.Data` call names the instance by its pid
  (`put_dynamic_repo/1`, scoped to that call). Its config (pragmas, pool
  size) is `config :nobi, Nobi.Data.Repo`.
  """

  use Ecto.Repo,
    otp_app: :nobi,
    adapter: Ecto.Adapters.SQLite3
end
