ExUnit.start()

{:ok, _} = Stc.Test.Repo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Stc.Test.Repo, :manual)
