defmodule Kinoko.Data.Repo do
  @moduledoc """
  The repo of a deployment's own SQLite file (`Kinoko.Data`).

  Never started by name and never in `ecto_repos`: `Kinoko.Data.Opener`
  starts one anonymous instance per file (`start_link(name: nil, database:
  path)`), and every `Kinoko.Data` call names the instance by its pid
  (`put_dynamic_repo/1`, scoped to that call). Its config (pragmas, pool
  size) is `config :kinoko, Kinoko.Data.Repo`.
  """

  use Ecto.Repo,
    otp_app: :kinoko,
    adapter: Ecto.Adapters.SQLite3
end
