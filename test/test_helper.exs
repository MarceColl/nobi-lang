ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Nobi.Repo, :manual)
# Quint conformance is slow (~80 s): opt in with `mix test --include quint`.
# Tests that assert wall-clock bounds are tagged :perf and flake under load:
# opt in with `mix test --include perf`.
ExUnit.configure(exclude: [:quint, :perf])
