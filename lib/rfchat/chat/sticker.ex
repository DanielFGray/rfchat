defmodule Rfchat.Chat.Sticker do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stickers" do
    field(:name, :string)
    field(:description, :string)
    field(:tags, {:array, :string}, default: [])
    field(:format, Ecto.Enum, values: [:png, :apng, :gif, :lottie], default: :png)
    field(:available, :boolean, default: true)
    field(:sort_value, :integer, default: 0)

    belongs_to(:asset, Rfchat.Chat.MediaAsset)
    belongs_to(:creator, Rfchat.Chat.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(sticker, attrs) do
    sticker
    |> cast(attrs, [
      :name,
      :description,
      :tags,
      :format,
      :asset_id,
      :creator_id,
      :available,
      :sort_value
    ])
    |> validate_required([:name, :format, :asset_id])
    |> validate_length(:name, min: 2, max: 64)
    |> unique_constraint(:name)
  end
end
