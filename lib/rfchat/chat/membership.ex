defmodule Rfchat.Chat.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "memberships" do
    field(:nickname, :string)
    field(:pronouns, :string)
    field(:joined_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:timeout_until, :utc_datetime_usec)
    field(:deactivated_at, :utc_datetime_usec)
    field(:is_owner, :boolean, default: false)
    field(:flags, :map, default: %{})

    belongs_to(:user, Rfchat.Chat.User)
    belongs_to(:server_avatar_asset, Rfchat.Chat.MediaAsset)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [
      :user_id,
      :nickname,
      :pronouns,
      :server_avatar_asset_id,
      :joined_at,
      :last_seen_at,
      :timeout_until,
      :deactivated_at,
      :is_owner,
      :flags
    ])
    |> validate_required([:user_id, :joined_at])
    |> validate_length(:nickname, max: 40)
    |> validate_length(:pronouns, max: 32)
    |> unique_constraint(:user_id)
  end
end
