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

  def ownership_changeset(membership, is_owner) when is_boolean(is_owner) do
    membership
    |> change()
    |> put_change(:is_owner, is_owner)
  end

  @doc """
  Records that a user joined the server. The membership's `user_id` comes from the struct the
  caller builds, so no attrs are cast.
  """
  def join_changeset(membership, joined_at) do
    membership
    |> change(joined_at: joined_at)
    |> validate_required([:user_id, :joined_at])
    |> unique_constraint(:user_id)
  end

  @doc """
  Sets or clears the timeout. Passing `nil` lifts it.
  """
  def timeout_changeset(membership, timeout_until) do
    change(membership, timeout_until: timeout_until)
  end

  @doc """
  Deactivates the membership and replaces its flags with `flags`. Deactivation also clears any
  timeout, so a deactivated member carries no stale timeout.
  """
  def deactivate_changeset(membership, deactivated_at, flags) when is_map(flags) do
    change(membership, deactivated_at: deactivated_at, timeout_until: nil, flags: flags)
  end
end
