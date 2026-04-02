defmodule Rfchat.Repo.Migrations.CreateChatDomain do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:username, :string, null: false)
      add(:display_name, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:users, [:username]))

    create table(:channels, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:position, :integer, null: false, default: 0)
      add(:topic, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:channels, [:slug]))
    create(unique_index(:channels, [:position]))

    create table(:messages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:body, :text, null: false)

      add(:channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:author_id, references(:users, type: :binary_id, on_delete: :restrict), null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:messages, [:channel_id, :inserted_at]))
    create(index(:messages, [:author_id, :inserted_at]))
  end
end
