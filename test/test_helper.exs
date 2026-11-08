# The test database is on the platform Postgres, reached through an SSH tunnel.
ExUnit.start(assert_receive_timeout: 1_000)
Rfchat.TestDatabase.truncate!()
Ecto.Adapters.SQL.Sandbox.mode(Rfchat.Repo, :manual)
