defmodule Tavern.Chat.ChannelNotificationOverride do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channel_notification_overrides" do
    field(:level, Ecto.Enum,
      values: [:default, :all_messages, :mentions, :nothing],
      default: :default
    )

    field(:muted_until, :utc_datetime_usec)

    belongs_to(:user, Tavern.Chat.User)
    belongs_to(:channel, Tavern.Chat.Channel)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:user_id, :channel_id, :level, :muted_until])
    |> validate_required([:user_id, :channel_id, :level])
    |> unique_constraint([:user_id, :channel_id])
  end
end
