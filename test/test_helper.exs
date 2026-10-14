ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Kinoko.Repo, :manual)
ExUnit.configure(exclude: if(System.find_executable("quint"), do: [], else: [:quint]))
