defmodule Tavern.Repo.Migrations.GrantVisitorRole do
  @moduledoc """
  Gives the database's visitor role, which the app's runtime login switches to, read and
  write access to every table and sequence, now and in later migrations.

  The platform names the visitor role per database instance (live, staged, each checkout's
  dev database) and grants it nothing itself, so the name comes from `DATABASE_VISITOR`.
  Migrations run as the owner role, so the default privileges cover every table they create.
  """
  use Ecto.Migration

  def up do
    visitor = visitor_role()

    execute "GRANT USAGE ON SCHEMA public TO #{visitor}"
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{visitor}"
    execute "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{visitor}"
    execute "REVOKE ALL ON TABLE schema_migrations FROM #{visitor}"

    execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public " <>
              "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{visitor}"

    execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public " <>
              "GRANT USAGE, SELECT ON SEQUENCES TO #{visitor}"
  end

  def down do
    visitor = visitor_role()

    execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public " <>
              "REVOKE USAGE, SELECT ON SEQUENCES FROM #{visitor}"

    execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public " <>
              "REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM #{visitor}"

    execute "REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM #{visitor}"
    execute "REVOKE ALL ON ALL TABLES IN SCHEMA public FROM #{visitor}"
    execute "REVOKE USAGE ON SCHEMA public FROM #{visitor}"
  end

  defp visitor_role do
    name = System.fetch_env!("DATABASE_VISITOR")
    ~s("#{String.replace(name, ~s("), ~s(""))}")
  end
end
