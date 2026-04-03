defmodule Rfchat.Chat.MediaAsset do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "media_assets" do
    field(:kind, Ecto.Enum,
      values: [
        :avatar,
        :banner,
        :attachment,
        :emoji,
        :sticker,
        :role_icon,
        :server_avatar,
        :server_icon,
        :other
      ]
    )

    field(:storage_provider, :string, default: "local")
    field(:storage_key, :string)
    field(:original_filename, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:sha256, :string)
    field(:width, :integer)
    field(:height, :integer)
    field(:duration_ms, :integer)
    field(:metadata, :map, default: %{})

    belongs_to(:uploader, Rfchat.Chat.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :uploader_id,
      :kind,
      :storage_provider,
      :storage_key,
      :original_filename,
      :content_type,
      :byte_size,
      :sha256,
      :width,
      :height,
      :duration_ms,
      :metadata
    ])
    |> validate_required([:kind, :storage_provider, :storage_key, :byte_size])
    |> validate_length(:storage_key, min: 1, max: 255)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> unique_constraint([:storage_provider, :storage_key])
  end
end
