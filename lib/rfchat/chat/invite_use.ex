defmodule Rfchat.Chat.InviteUse do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "invite_uses" do
    field(:used_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    belongs_to(:invite, Rfchat.Chat.Invite)
    belongs_to(:user, Rfchat.Chat.User)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(invite_use, attrs) do
    invite_use
    |> cast(attrs, [:invite_id, :user_id, :used_at, :metadata])
    |> validate_required([:invite_id, :user_id, :used_at])
  end
end
