defmodule Tavern.Chat.ChannelMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channel_memberships" do
    field(:last_read_at, :utc_datetime_usec)

    field(:notification_level, Ecto.Enum,
      values: [:default, :all_messages, :mentions, :nothing],
      default: :default
    )

    field(:muted_until, :utc_datetime_usec)
    field(:is_favorite, :boolean, default: false)
    field(:joined_at, :utc_datetime_usec)

    belongs_to(:channel, Tavern.Chat.Channel)
    belongs_to(:user, Tavern.Chat.User)
    belongs_to(:last_read_message, Tavern.Chat.Message)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(channel_membership, attrs) do
    channel_membership
    |> cast(attrs, [
      :channel_id,
      :user_id,
      :last_read_message_id,
      :last_read_at,
      :notification_level,
      :muted_until,
      :is_favorite,
      :joined_at
    ])
    |> validate_required([:channel_id, :user_id, :joined_at])
    |> unique_constraint([:channel_id, :user_id])
  end
end
