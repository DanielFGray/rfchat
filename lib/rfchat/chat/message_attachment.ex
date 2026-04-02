defmodule Rfchat.Chat.MessageAttachment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_attachments" do
    field(:kind, Ecto.Enum, values: [:file, :image, :video, :audio], default: :file)
    field(:position, :integer, default: 0)
    field(:description, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:message, Rfchat.Chat.Message)
    belongs_to(:asset, Rfchat.Chat.MediaAsset)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:message_id, :asset_id, :kind, :position, :description, :metadata])
    |> validate_required([:message_id, :asset_id, :kind, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:message_id, :position])
  end
end
