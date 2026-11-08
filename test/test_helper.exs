# The test database is on the platform Postgres, reached through an SSH tunnel.
ExUnit.start(assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(Rfchat.Repo, :manual)
