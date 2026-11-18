defmodule Tavern.TestDatabase do
  @moduledoc """
  The platform gives a checkout one test database, and the ExUnit suite and the Playwright
  suite share it. Each suite empties it when it starts, so neither depends on the other to
  clean up after itself.
  """

  alias Tavern.Repo

  @doc """
  Truncates every table except `schema_migrations` and restarts the sequences. It runs
  outside the SQL sandbox, so the change commits.
  """
  def truncate! do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      %{rows: tables} =
        Repo.query!("""
        SELECT format('%I.%I', schemaname, tablename)
        FROM pg_tables
        WHERE schemaname = 'public' AND tablename <> 'schema_migrations'
        """)

      Repo.query!("TRUNCATE #{Enum.map_join(tables, ", ", &hd/1)} RESTART IDENTITY CASCADE")
    end)

    :ok
  end
end
