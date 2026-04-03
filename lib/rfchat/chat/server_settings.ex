defmodule Rfchat.Chat.ServerSettings do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "server_settings" do
    field(:singleton, :boolean, default: true)
    field(:name, :string)

    belongs_to(:icon_asset, Rfchat.Chat.MediaAsset)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(server_settings, attrs) do
    server_settings
    |> cast(attrs, [:singleton, :name, :icon_asset_id])
    |> validate_required([:singleton, :name])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:singleton)
  end
end
