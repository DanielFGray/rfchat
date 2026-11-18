defmodule Rfchat.Chat.ChannelPermissionOverwrite do
  use Ecto.Schema
  import Bitwise
  import Ecto.Changeset

  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.PermissionBits

  @administrator PermissionBits.flag(:administrator)
  @overwritable_bits band(Authorization.all_permissions(), bnot(@administrator))

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channel_permission_overwrites" do
    field(:allow_permissions, :integer, default: 0)
    field(:deny_permissions, :integer, default: 0)

    belongs_to(:channel, Rfchat.Chat.Channel)
    belongs_to(:role, Rfchat.Chat.Role)
    belongs_to(:user, Rfchat.Chat.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(overwrite, attrs) do
    overwrite
    |> cast(attrs, [:channel_id, :role_id, :user_id, :allow_permissions, :deny_permissions])
    |> validate_required([:channel_id])
    |> validate_number(:allow_permissions, greater_than_or_equal_to: 0)
    |> validate_number(:deny_permissions, greater_than_or_equal_to: 0)
    |> validate_bits(:allow_permissions)
    |> validate_bits(:deny_permissions)
    |> validate_disjoint()
    |> unique_constraint([:channel_id, :role_id])
    |> unique_constraint([:channel_id, :user_id])
    |> validate_target_choice()
  end

  # An overwrite holds only known bits, and never `administrator`: administrator is a server bit
  # that bypasses every overwrite, so a channel cannot grant or take it.
  defp validate_bits(changeset, field) do
    validate_change(changeset, field, fn ^field, bits ->
      cond do
        band(bits, bnot(@overwritable_bits)) == 0 -> []
        band(bits, @administrator) != 0 -> [{field, "cannot include administrator"}]
        true -> [{field, "includes an unknown permission"}]
      end
    end)
  end

  defp validate_disjoint(changeset) do
    allow = get_field(changeset, :allow_permissions) || 0
    deny = get_field(changeset, :deny_permissions) || 0

    if band(allow, deny) == 0,
      do: changeset,
      else: add_error(changeset, :deny_permissions, "cannot deny a permission it allows")
  end

  defp validate_target_choice(changeset) do
    role_id = get_field(changeset, :role_id)
    user_id = get_field(changeset, :user_id)

    case {role_id, user_id} do
      {nil, nil} -> add_error(changeset, :role_id, "or user must be present")
      {_, nil} -> changeset
      {nil, _} -> changeset
      {_, _} -> add_error(changeset, :user_id, "cannot coexist with role target")
    end
  end
end
