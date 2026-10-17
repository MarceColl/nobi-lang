defmodule Nobi.Repo do
  use Ecto.Repo,
    otp_app: :nobi,
    adapter: Ecto.Adapters.SQLite3
end
