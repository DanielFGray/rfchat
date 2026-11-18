defmodule Rfchat.Bots.Authority do
  @moduledoc """
  Decides which bots a member may control and which roles a member may give a bot.

  A bot token acts with the bot's roles, and whoever creates a bot or mints its token holds that
  token. So controlling a bot is the same as holding every permission its roles grant: a member
  may control a bot, or give it a role, only with authority over each of those roles under
  `Rfchat.Chat.RoleAuthority`, the rule people use to give roles to people.
  """

  import Ecto.Query, warn: false

  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.RoleAuthority
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  @doc "The actor's current authority, when the actor may manage bots."
  def manage_bots(%User{id: actor_id}) do
    authority = RoleAuthority.load(%Scope{user_id: actor_id})

    if Authorization.has_permission?(authority.permissions, :manage_bots),
      do: {:ok, authority},
      else: {:error, :forbidden}
  end

  @doc "The roles behind `role_ids`, when the authority may give every one of them to a bot."
  def grant_roles(%RoleAuthority{} = authority, role_ids) do
    case role_ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() do
      [] ->
        {:ok, []}

      ids ->
        with true <- RoleAuthority.manage_roles?(authority),
             {:ok, roles} <- fetch_roles(ids),
             true <- Enum.all?(roles, &RoleAuthority.givable?/1),
             true <- RoleAuthority.within?(authority, roles) do
          {:ok, roles}
        else
          _ -> {:error, :forbidden}
        end
    end
  end

  @doc """
  `:ok` when the authority may change, mint tokens for, or revoke this bot. Reloads the bot's
  roles, so a caller holding the role-list lock decides from current positions.
  """
  def control_bot(%RoleAuthority{} = authority, %User{bot: true} = bot_user) do
    roles =
      bot_user
      |> Repo.preload([member_roles: :role], force: true)
      |> Map.fetch!(:member_roles)
      |> Enum.map(& &1.role)

    if RoleAuthority.within?(authority, roles), do: :ok, else: {:error, :forbidden}
  end

  @doc "Every role the authority may give a bot, highest first."
  def grantable_roles(%RoleAuthority{} = authority) do
    if RoleAuthority.manage_roles?(authority) do
      roles =
        Role
        |> where([role], role.is_default == false and role.managed == false)
        |> order_by([role], desc: role.position, asc: role.name)
        |> Repo.all()

      RoleAuthority.within(authority, roles)
    else
      []
    end
  end

  defp fetch_roles(ids) do
    if Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      roles = Repo.all(from(role in Role, where: role.id in ^ids))
      if length(roles) == length(ids), do: {:ok, roles}, else: :error
    else
      :error
    end
  end
end
