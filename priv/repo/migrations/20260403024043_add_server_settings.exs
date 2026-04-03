defmodule Rfchat.Repo.Migrations.AddServerSettings do
  use Ecto.Migration

  def change do
    create table(:server_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:singleton, :boolean, null: false, default: true)
      add(:name, :string, null: false)
      add(:icon_asset_id, references(:media_assets, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:server_settings, [:singleton]))
    create(index(:server_settings, [:icon_asset_id]))
  end
end
