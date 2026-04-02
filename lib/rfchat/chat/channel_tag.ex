defmodule Rfchat.Chat.ChannelTag do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channel_tags" do
    field(:name, :string)
    field(:emoji_unicode, :string)
    field(:moderated, :boolean, default: false)
    field(:position, :integer, default: 0)

    belongs_to(:channel, Rfchat.Chat.Channel)
    belongs_to(:emoji, Rfchat.Chat.Emoji)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:channel_id, :name, :emoji_id, :emoji_unicode, :moderated, :position])
    |> validate_required([:channel_id, :name])
    |> validate_length(:name, min: 1, max: 32)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:channel_id, :name])
  end
end
