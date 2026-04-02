defmodule Rfchat.Chat.ChannelTagAssignment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channel_tag_assignments" do
    belongs_to(:thread_channel, Rfchat.Chat.Channel)
    belongs_to(:tag, Rfchat.Chat.ChannelTag)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:thread_channel_id, :tag_id])
    |> validate_required([:thread_channel_id, :tag_id])
    |> unique_constraint([:thread_channel_id, :tag_id])
  end
end
