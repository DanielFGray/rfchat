defmodule Rfchat.Chat.Invite do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "invites" do
    field(:code, :string)
    field(:max_uses, :integer)
    field(:uses, :integer, default: 0)
    field(:expires_at, :utc_datetime_usec)
    field(:temporary, :boolean, default: false)
    field(:revoked_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)

    belongs_to(:channel, Rfchat.Chat.Channel)
    belongs_to(:inviter, Rfchat.Chat.User)

    has_many(:invite_uses, Rfchat.Chat.InviteUse)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [
      :code,
      :channel_id,
      :inviter_id,
      :max_uses,
      :uses,
      :expires_at,
      :temporary,
      :revoked_at,
      :last_used_at
    ])
    |> validate_required([:code, :channel_id])
    |> validate_length(:code, min: 4, max: 32)
    |> validate_number(:uses, greater_than_or_equal_to: 0)
    |> unique_constraint(:code)
  end
end
