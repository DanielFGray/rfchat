defmodule Rfchat.Bots.Authority do
  @moduledoc """
  Decides which bots and roles a member may control.

  A bot token acts with the bot's roles, and whoever creates a bot or mints its token holds
  that token. So controlling a bot is the same as holding every permission its roles grant.
  A member may therefore control a bot, or give it a role, only when each role sits below
  the member's highest role, grants no server-wide permission the member lacks, and grants
  no channel permission through a role overwrite that the member lacks in that channel.
  Only the server owner may hand out the administrator permission, and the owner is bound
  by no other rule.

  Authority is read from the database on every call: a session's scope can be stale after
  a role change or a demotion.
  """

  import Bitwise
  import Ecto.Query, warn: false

  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.ChannelPermissionOverwrite
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.Permissions
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  defstruct [:user, owner?: false, permissions: 0, top_position: 0]

  @administrator PermissionBits.flag(:administrator)

  @doc "The actor's current authority, when the actor may manage bots."
  def manage_bots(%User{id: actor_id}) do
    with %User{} = user <- Permissions.current_member(actor_id),
         authority = authority(user),
         true <- Authorization.has_permission?(authority.permissions, :manage_bots) do
      {:ok, authority}
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc "The roles behind `role_ids`, when the authority may give every one of them to a bot."
  def grant_roles(%__MODULE__{} = authority, role_ids) do
    case role_ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() do
      [] ->
        {:ok, []}

      ids ->
        with true <- Authorization.has_permission?(authority.permissions, :manage_roles),
             {:ok, roles} <- fetch_roles(ids),
             overwrites_by_role = overwrites_by_role_id(Enum.map(roles, & &1.id)),
             true <- Enum.all?(roles, &grantable?(authority, &1, overwrites_by_role)) do
          {:ok, roles}
        else
          _ -> {:error, :forbidden}
        end
    end
  end

  @doc "`:ok` when the authority may change, mint tokens for, or revoke this bot."
  def control_bot(%__MODULE__{} = authority, %User{bot: true} = bot_user) do
    roles =
      bot_user
      |> Repo.preload(member_roles: :role)
      |> Map.fetch!(:member_roles)
      |> Enum.map(& &1.role)

    overwrites_by_role = overwrites_by_role_id(Enum.map(roles, & &1.id))

    if Enum.all?(roles, &grantable?(authority, &1, overwrites_by_role)),
      do: :ok,
      else: {:error, :forbidden}
  end

  @doc "Every role the authority may give a bot, highest first."
  def grantable_roles(%__MODULE__{} = authority) do
    if Authorization.has_permission?(authority.permissions, :manage_roles) do
      roles =
        Role
        |> where([role], role.is_default == false)
        |> order_by([role], desc: role.position, asc: role.name)
        |> Repo.all()

      overwrites_by_role = overwrites_by_role_id(Enum.map(roles, & &1.id))
      Enum.filter(roles, &grantable?(authority, &1, overwrites_by_role))
    else
      []
    end
  end

  defp grantable?(%__MODULE__{owner?: true}, %Role{is_default: false}, _overwrites_by_role),
    do: true

  defp grantable?(%__MODULE__{} = authority, %Role{is_default: false} = role, overwrites_by_role) do
    role.position < authority.top_position and band(role.permissions, @administrator) == 0 and
      band(role.permissions, bnot(authority.permissions)) == 0 and
      channel_overwrites_grantable?(
        authority,
        Map.get(overwrites_by_role, role.id, [])
      )
  end

  defp grantable?(_authority, %Role{}, _overwrites_by_role), do: false

  # A role overwrite may allow bits the member does not have in that channel; granting it
  # would let a bot token act where the member cannot.
  defp channel_overwrites_grantable?(%__MODULE__{} = authority, overwrites) do
    default_role = Permissions.default_role()

    Enum.all?(overwrites, fn overwrite ->
      actor_permissions =
        Authorization.channel_permissions(authority.user, overwrite.channel, default_role)

      band(overwrite.allow_permissions, bnot(actor_permissions)) == 0
    end)
  end

  defp overwrites_by_role_id([]), do: %{}

  defp overwrites_by_role_id(role_ids) do
    from(overwrite in ChannelPermissionOverwrite,
      where: overwrite.role_id in ^Enum.uniq(role_ids),
      preload: [channel: :permission_overwrites]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.role_id)
  end

  defp authority(%User{} = user) do
    %__MODULE__{
      user: user,
      owner?: active_owner?(user),
      permissions: Authorization.base_permissions(user, Permissions.default_role()),
      top_position: Permissions.top_role_position(user)
    }
  end

  defp active_owner?(%User{membership: %{is_owner: true, deactivated_at: nil}}), do: true
  defp active_owner?(%User{}), do: false

  defp fetch_roles(ids) do
    if Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      roles = Repo.all(from(role in Role, where: role.id in ^ids))
      if length(roles) == length(ids), do: {:ok, roles}, else: :error
    else
      :error
    end
  end
end
