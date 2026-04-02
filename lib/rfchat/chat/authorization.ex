defmodule Rfchat.Chat.Authorization do
  @moduledoc false

  import Bitwise

  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.ChannelPermissionOverwrite
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User

  @all_permissions PermissionBits.flags() |> Map.keys() |> PermissionBits.combine()

  def all_permissions, do: @all_permissions

  def base_permissions(%User{} = user, %Role{} = default_role) do
    user
    |> do_base_permissions(default_role.permissions)
    |> expand_administrator()
  end

  def base_permissions(%User{} = user, nil) do
    user
    |> do_base_permissions(0)
    |> expand_administrator()
  end

  def channel_permissions(%User{} = user, %Channel{} = channel, default_role) do
    base_permissions = base_permissions(user, default_role)

    cond do
      base_permissions == 0 ->
        0

      administrator?(base_permissions) ->
        @all_permissions

      true ->
        apply_channel_overwrites(
          base_permissions,
          user,
          channel.permission_overwrites || [],
          default_role
        )
    end
  end

  def can_view_channel?(%User{} = user, %Channel{} = channel, default_role) do
    channel_permissions(user, channel, default_role)
    |> has_permission?(:view_channel)
  end

  def can_send_messages?(%User{} = user, %Channel{} = channel, default_role) do
    permissions = channel_permissions(user, channel, default_role)

    has_permission?(permissions, :view_channel) and has_permission?(permissions, :send_messages)
  end

  def has_permission?(permissions, permission_name) when is_integer(permissions) do
    permission_bit = PermissionBits.flag(permission_name)
    band(permissions, permission_bit) == permission_bit
  end

  defp do_base_permissions(%User{membership: membership}, _default_permissions)
       when is_nil(membership) do
    0
  end

  defp do_base_permissions(
         %User{membership: %{deactivated_at: deactivated_at}},
         _default_permissions
       )
       when not is_nil(deactivated_at) do
    0
  end

  defp do_base_permissions(%User{membership: %{is_owner: true}}, _default_permissions),
    do: @all_permissions

  defp do_base_permissions(%User{} = user, default_permissions) do
    Enum.reduce(user.member_roles || [], default_permissions, fn member_role, permissions ->
      permissions ||| member_role.role.permissions
    end)
  end

  defp expand_administrator(permissions) do
    if administrator?(permissions), do: @all_permissions, else: permissions
  end

  defp administrator?(permissions), do: has_permission?(permissions, :administrator)

  defp apply_channel_overwrites(base_permissions, %User{} = user, overwrites, default_role) do
    {everyone_deny, everyone_allow} =
      overwrites
      |> Enum.filter(&matches_default_role?(&1, default_role))
      |> merge_overwrites()

    role_ids = MapSet.new(Enum.map(user.member_roles || [], & &1.role_id))

    {role_deny, role_allow} =
      overwrites
      |> Enum.filter(&matches_member_role?(&1, role_ids))
      |> merge_overwrites()

    {user_deny, user_allow} =
      overwrites
      |> Enum.filter(&(&1.user_id == user.id))
      |> merge_overwrites()

    base_permissions
    |> drop_permissions(everyone_deny)
    |> add_permissions(everyone_allow)
    |> drop_permissions(role_deny)
    |> add_permissions(role_allow)
    |> drop_permissions(user_deny)
    |> add_permissions(user_allow)
  end

  defp merge_overwrites(overwrites) do
    Enum.reduce(overwrites, {0, 0}, fn overwrite, {deny_permissions, allow_permissions} ->
      {
        deny_permissions ||| overwrite.deny_permissions,
        allow_permissions ||| overwrite.allow_permissions
      }
    end)
  end

  defp matches_default_role?(%ChannelPermissionOverwrite{role_id: role_id}, %Role{
         id: default_role_id
       }) do
    role_id == default_role_id
  end

  defp matches_default_role?(_overwrite, nil), do: false

  defp matches_member_role?(%ChannelPermissionOverwrite{role_id: nil}, _role_ids), do: false

  defp matches_member_role?(%ChannelPermissionOverwrite{role_id: role_id}, role_ids) do
    MapSet.member?(role_ids, role_id)
  end

  defp drop_permissions(permissions, denied_permissions),
    do: permissions &&& bnot(denied_permissions)

  defp add_permissions(permissions, allowed_permissions), do: permissions ||| allowed_permissions
end
