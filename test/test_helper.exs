ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Kinoko.Repo, :manual)
# Quint conformance is slow (~80 s): opt in with `mix test --include quint`.
ExUnit.configure(exclude: [:quint])
