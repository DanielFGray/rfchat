defmodule Tavern.Chat.RoleAuthority do
  @moduledoc """
  The one rule for which roles an actor may create, edit, move, delete, give or take. People
  (through `Tavern.Chat.Roles`) and bot management (through `Tavern.Bots.Authority`) both decide
  with it.

  An actor has authority over a role when:

  - the actor holds `manage_roles` (an administrator holds every bit);
  - the role sits below the actor's highest role;
  - the role grants no server bit the actor lacks, and never `administrator`;
  - each channel overwrite on the role allows no bit the actor lacks in that channel.

  The server owner passes all four. An administrator holds every bit in every channel, so the
  first and last rules pass; the position rule still binds, and the third still keeps the
  `administrator` bit back: only the owner sets or gives `administrator`.

  A role a member holds is part of what that member may do, and a bot token acts with its bot's
  roles. So giving a role, or controlling a bot, needs authority over the role: otherwise an
  actor could pass on bits they do not hold.

  The default role (`@everyone`) and managed roles are never given or taken, by anyone. The
  default role is always lowest; only its permissions are editable. A managed role that is not
  the default role is changed only by the system.

  Authority is read from the database each time it is loaded: a session's scope can be stale
  after a role change or a demotion.
  """

  import Bitwise
  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Authorization
  alias Tavern.Chat.ChannelPermissionOverwrite
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Role
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  defstruct [:scope, :owner?, :permissions, :top_position, channel_permissions: %{}]

  @administrator PermissionBits.flag(:administrator)

  @doc "The scope's current authority. A scope with no active member holds nothing."
  def load(%Scope{} = scope) do
    facts = Visibility.authority(scope, [])

    %__MODULE__{
      scope: scope,
      owner?: facts.owner?,
      permissions: facts.server_permissions,
      top_position: facts.top_role_position,
      channel_permissions: facts.channel_permissions
    }
  end

  @doc "Whether the authority holds `manage_roles`."
  def manage_roles?(%__MODULE__{permissions: permissions}),
    do: Authorization.has_permission?(permissions, :manage_roles)

  @doc "The permission bits the authority may put on a role."
  def grantable_bits(%__MODULE__{owner?: true}), do: Authorization.all_permissions()

  def grantable_bits(%__MODULE__{permissions: permissions}),
    do: band(permissions, bnot(@administrator))

  @doc "Whether the role sits below the authority's highest role. The owner is above every role."
  def below?(%__MODULE__{owner?: true}, %Role{}), do: true
  def below?(%__MODULE__{top_position: top}, %Role{position: position}), do: position < top

  @doc "Whether the authority has authority over every role in `roles` (see the moduledoc)."
  def within?(%__MODULE__{} = authority, roles) when is_list(roles),
    do: length(within(authority, roles)) == length(roles)

  @doc "The roles in `roles` the authority has authority over, in the same order."
  def within(%__MODULE__{owner?: true}, roles) when is_list(roles), do: roles

  def within(%__MODULE__{} = authority, roles) when is_list(roles) do
    overwrites_by_role = overwrites_by_role_id(roles)
    authority = with_channel_facts(authority, overwrites_by_role)

    Enum.filter(roles, fn role ->
      below?(authority, role) and
        band(role.permissions, bnot(grantable_bits(authority))) == 0 and
        channel_overwrites_within?(authority, Map.get(overwrites_by_role, role.id, []))
    end)
  end

  @doc "Whether a role may be given to or taken from a member at all."
  def givable?(%Role{is_default: false, managed: false}), do: true
  def givable?(%Role{}), do: false

  # A role overwrite may allow bits the actor does not have in that channel; passing the role on
  # would let its holder act where the actor cannot.
  defp channel_overwrites_within?(authority, overwrites) do
    Enum.all?(overwrites, fn overwrite ->
      actor_permissions = Map.get(authority.channel_permissions, overwrite.channel_id, 0)
      band(overwrite.allow_permissions, bnot(actor_permissions)) == 0
    end)
  end

  defp overwrites_by_role_id(roles) do
    case roles |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      role_ids ->
        from(overwrite in ChannelPermissionOverwrite, where: overwrite.role_id in ^role_ids)
        |> Repo.all()
        |> Enum.group_by(& &1.role_id)
    end
  end

  # The channel ids are known only once the overwrites are loaded, so the bits held in those
  # channels are read in a second load.
  defp with_channel_facts(authority, overwrites_by_role) do
    channel_ids =
      overwrites_by_role
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.channel_id)
      |> Enum.uniq()

    if channel_ids == [] do
      authority
    else
      facts = Visibility.authority(authority.scope, channel_ids)
      %{authority | channel_permissions: facts.channel_permissions}
    end
  end
end
