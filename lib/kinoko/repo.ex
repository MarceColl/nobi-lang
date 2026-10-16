defmodule Kinoko.Repo do
  use Ecto.Repo,
    otp_app: :kinoko,
    adapter: Ecto.Adapters.SQLite3
end
