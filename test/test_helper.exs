# The test database is on the dev Postgres server, reached through an SSH tunnel.
ExUnit.start(assert_receive_timeout: 1_000)
Tavern.TestDatabase.truncate!()
Ecto.Adapters.SQL.Sandbox.mode(Tavern.Repo, :manual)
