defmodule Rfchat.Repo.Migrations.AddAuthToUsersAndSessions do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext")

    alter table(:users) do
      add(:email, :citext)
      add(:hashed_password, :string)
      add(:confirmed_at, :utc_datetime_usec)
    end

    create(unique_index(:users, [:email]))

    alter table(:user_sessions) do
      add(:context, :string, null: false, default: "session")
      add(:sent_to, :string)
    end

    create(index(:user_sessions, [:user_id, :context]))
  end
end
