defmodule Rfchat.Bots.Authority do
  @moduledoc """
  Decides which bots and roles a member may control.

  A bot token acts with the bot's roles, and whoever creates a bot or mints its token holds
  that token. So controlling a bot is the same as holding every permission its roles grant.
  A member may therefore control a bot, or give it a role, only when each role sits below
  the member's highest role and grants no permission the member lacks. Only the server owner
  may hand out the administrator permission, and the owner is bound by no other rule.

  Authority is read from the database on every call: a session's scope can be stale after
  a role change or a demotion.
  """

  import Bitwise
  import Ecto.Query, warn: false

  alias Rfchat.Chat.Authorization
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
             true <- Enum.all?(roles, &grantable?(authority, &1)) do
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

    if Enum.all?(roles, &grantable?(authority, &1)), do: :ok, else: {:error, :forbidden}
  end

  @doc "Every role the authority may give a bot, highest first."
  def grantable_roles(%__MODULE__{} = authority) do
    if Authorization.has_permission?(authority.permissions, :manage_roles) do
      Role
      |> where([role], role.is_default == false)
      |> order_by([role], desc: role.position, asc: role.name)
      |> Repo.all()
      |> Enum.filter(&grantable?(authority, &1))
    else
      []
    end
  end

  defp grantable?(%__MODULE__{owner?: true}, %Role{is_default: false}), do: true

  defp grantable?(%__MODULE__{} = authority, %Role{is_default: false} = role) do
    role.position < authority.top_position and band(role.permissions, @administrator) == 0 and
      band(role.permissions, bnot(authority.permissions)) == 0
  end

  defp grantable?(_authority, %Role{}), do: false

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
