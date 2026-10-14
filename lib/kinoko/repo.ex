defmodule Kinoko.Repo do
  use Ecto.Repo,
    otp_app: :kinoko,
    adapter: Ecto.Adapters.Postgres
end
