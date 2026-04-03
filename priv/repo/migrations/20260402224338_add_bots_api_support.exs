defmodule Rfchat.Repo.Migrations.AddBotsApiSupport do
  use Ecto.Migration

  def change do
    create table(:bot_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :token_hash, :binary, null: false
      add :label, :string
      add :last_used_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:bot_tokens, [:token_hash])
    create index(:bot_tokens, [:user_id, :inserted_at])
  end
end
