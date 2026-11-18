defmodule Rfchat.Chat.Roles do
  @moduledoc """
  Role management: list, create, edit, move and delete roles, and give and take member roles.

  Every write decides inside its transaction, with the rule in `Rfchat.Chat.RoleAuthority`, and
  takes its locks in this order (docs/design/roles.md):

  1. the role-list advisory lock (`Visibility.lock_role_list!/0`), so role writes never
     interleave;
  2. the membership rows, through `Visibility.authorize_write/3`: the actor's row `FOR SHARE`,
     or for a member role change (`:assign_roles`) the actor's and the subject's rows
     `FOR UPDATE`, in id order;
  3. the target role row.

  Non-default roles hold the positions `n..1`, highest first; the default role holds 0. Every
  write that adds, moves or removes a role renumbers the others in order, so positions stay
  distinct and "below" is always strict.

  A hidden or missing role or member answers `{:error, :not_found}`; a visible one the scope may
  not change answers `{:error, :forbidden}`. Each write that changes something records an audit log
  entry and broadcasts `:roles_changed` on the guild topic after it commits; a move at the edge,
  giving a held role or taking one not held changes nothing and records nothing.
  """

  import Ecto.Query, warn: false

  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.AuditLogEntry
  alias Rfchat.Chat.MemberRole
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.RoleAuthority
  alias Rfchat.Chat.Topics
  alias Rfchat.Chat.User
  alias Rfchat.Chat.Visibility
  alias Rfchat.Repo

  @doc """
  Every role, highest first, with `member_count` set to its active members (the default role
  counts every active member). A scope that is not an active member gets none.
  """
  def list_roles(%Scope{} = scope) do
    if is_nil(Visibility.member(scope)) do
      []
    else
      counts = member_counts()

      Enum.map(ordered_roles(), fn role ->
        count = if role.is_default, do: counts.all, else: Map.get(counts.by_role, role.id, 0)
        %{role | member_count: count}
      end)
    end
  end

  @doc """
  What the scope may do with roles, for the settings screen to decide what to show:
  `manage_roles?`, `grantable_permissions` (bits it may put on a role), `manageable_role_ids`
  (roles it may edit) and `givable_role_ids` (roles it may give or take).
  Writes decide again on their own.
  """
  def role_controls(%Scope{} = scope) do
    authority = RoleAuthority.load(scope)

    if RoleAuthority.manage_roles?(authority) do
      roles = authority |> RoleAuthority.within(ordered_roles()) |> Enum.filter(&editable?/1)

      %{
        manage_roles?: true,
        grantable_permissions: RoleAuthority.grantable_bits(authority),
        manageable_role_ids: MapSet.new(roles, & &1.id),
        givable_role_ids: roles |> Enum.filter(&RoleAuthority.givable?/1) |> MapSet.new(& &1.id)
      }
    else
      %{
        manage_roles?: false,
        grantable_permissions: 0,
        manageable_role_ids: MapSet.new(),
        givable_role_ids: MapSet.new()
      }
    end
  end

  @doc "The roles an active member holds, highest first, or nil when the member is hidden."
  def member_roles(%Scope{} = scope, user_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %User{} <- Visibility.member(scope),
         true <- active_member?(user_id) do
      from(role in Role,
        join: member_role in MemberRole,
        on: member_role.role_id == role.id,
        where: member_role.user_id == ^user_id,
        order_by: [desc: role.position, asc: role.name]
      )
      |> Repo.all()
    else
      _ -> nil
    end
  end

  def change_role(%Role{} = role, attrs \\ %{}), do: Role.manage_changeset(role, attrs)

  @doc "Creates a role just above the default role."
  def create_role(%Scope{} = scope, attrs) do
    write(scope, "role_created", nil, fn ->
      with :ok <- Visibility.authorize_write(scope, :manage_roles, :server),
           authority = RoleAuthority.load(scope),
           changeset = Role.manage_changeset(%Role{position: 1}, attrs),
           {:ok, draft} <- Ecto.Changeset.apply_action(changeset, :insert),
           :ok <- permit(RoleAuthority.within?(authority, [draft])),
           {:ok, role} <- Repo.insert(changeset) do
        renumber!(ranked_roles(role.id) ++ [role])
        {:ok, Repo.get!(Role, role.id)}
      end
    end)
  end

  @doc """
  Edits a role. The actor needs authority over the role as it stands and as it will be, so an
  edit never strips or adds a bit the actor does not hold.
  """
  def update_role(%Scope{} = scope, role_id, attrs) do
    write_role(scope, role_id, "role_updated", fn authority, role ->
      changeset = Role.manage_changeset(role, attrs)

      with :ok <- permit(editable?(role) and RoleAuthority.within?(authority, [role])),
           {:ok, draft} <- Ecto.Changeset.apply_action(changeset, :update),
           :ok <- permit(RoleAuthority.within?(authority, [draft])) do
        Repo.update(changeset)
      end
    end)
  end

  @doc "Deletes a role. Its member roles, overwrites, emoji limits and mentions go with it."
  def delete_role(%Scope{} = scope, role_id) do
    write_role(scope, role_id, "role_deleted", fn authority, role ->
      with :ok <- permit(changeable?(role) and RoleAuthority.within?(authority, [role])),
           {:ok, deleted} <- Repo.delete(role) do
        renumber!(ranked_roles())
        {:ok, deleted}
      end
    end)
  end

  @doc """
  Swaps a role with its neighbour above (`:up`) or below (`:down`). Both must sit below the
  actor. A role at the edge stays where it is.
  """
  def move_role(%Scope{} = scope, role_id, direction) do
    write_role(scope, role_id, "role_moved", fn authority, role ->
      with :ok <- permit(changeable?(role) and RoleAuthority.within?(authority, [role])),
           {:ok, delta} <- direction_delta(direction) do
        roles = ranked_roles()
        index = Enum.find_index(roles, &(&1.id == role.id))
        neighbour_index = index + delta

        if neighbour_index < 0 or neighbour_index >= length(roles) do
          {:unchanged, role}
        else
          neighbour = Enum.at(roles, neighbour_index)

          with :ok <- permit(RoleAuthority.below?(authority, neighbour)) do
            roles
            |> List.replace_at(index, neighbour)
            |> List.replace_at(neighbour_index, role)
            |> renumber!()

            {:ok, Repo.get!(Role, role.id)}
          end
        end
      end
    end)
  end

  @doc "Gives a role to an active member."
  def add_member_role(%Scope{} = scope, user_id, role_id) do
    write_member_role(scope, user_id, role_id, "member_role_added", fn role, subject_id ->
      held? =
        Repo.exists?(
          from(member_role in MemberRole,
            where: member_role.user_id == ^subject_id and member_role.role_id == ^role.id
          )
        )

      if held? do
        {:unchanged, role}
      else
        %MemberRole{user_id: subject_id, role_id: role.id, granted_by_user_id: scope.user_id}
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:user_id, :role_id])

        {:ok, role}
      end
    end)
  end

  @doc "Takes a role from an active member."
  def remove_member_role(%Scope{} = scope, user_id, role_id) do
    write_member_role(scope, user_id, role_id, "member_role_removed", fn role, subject_id ->
      from(member_role in MemberRole,
        where: member_role.user_id == ^subject_id and member_role.role_id == ^role.id
      )
      |> Repo.delete_all()
      |> case do
        {0, _} -> {:unchanged, role}
        {_count, _} -> {:ok, role}
      end
    end)
  end

  # --- Transactions ------------------------------------------------------------------------------

  # `change` returns `{:ok, role}` when it changed something, which is audited and broadcast, or
  # `{:unchanged, role}` (a move at the edge, giving a held role), which commits nothing.
  defp write(scope, action_type, subject_id, change) do
    Repo.transact(fn ->
      Visibility.lock_role_list!()

      case change.() do
        {:ok, role} ->
          record_audit_log!(scope, action_type, role, subject_id)
          {:ok, {:changed, role}}

        {:unchanged, role} ->
          {:ok, {:unchanged, role}}

        error ->
          error
      end
    end)
    |> case do
      {:ok, {:changed, role}} ->
        Topics.broadcast_guild(:roles_changed)
        {:ok, role}

      {:ok, {:unchanged, role}} ->
        {:ok, role}

      error ->
        error
    end
  end

  # Takes the actor's membership row, then the role row, then decides with the actor's authority.
  defp write_role(scope, role_id, action_type, change) do
    case Ecto.UUID.cast(role_id) do
      {:ok, role_id} ->
        write(scope, action_type, nil, fn ->
          case Visibility.authorize_write(scope, :manage_roles, :server) do
            :ok ->
              with {:ok, role} <- lock_role(role_id), do: change.(RoleAuthority.load(scope), role)

            {:error, :forbidden} ->
              refusal(scope, role_id)
          end
        end)

      :error ->
        {:error, :not_found}
    end
  end

  # A member role change decides `:assign_roles`: it locks both membership rows and requires the
  # subject to be the actor or a member whose top role is below the actor's (the owner: anyone). Visibility is
  # checked after the locks and before the decision's answer: an actor that is not an active
  # member, a subject that has left or been removed, and a missing role are all `:not_found`.
  defp write_member_role(scope, user_id, role_id, action_type, change) do
    with {:ok, subject_id} <- cast_id(user_id),
         {:ok, role_id} <- cast_id(role_id) do
      write(scope, action_type, subject_id, fn ->
        decision = Visibility.authorize_write(scope, :assign_roles, subject_id)

        with :ok <- visible_subject(scope, subject_id),
             {:ok, role} <- lock_role(role_id),
             :ok <- decision,
             authority = RoleAuthority.load(scope),
             :ok <-
               permit(RoleAuthority.givable?(role) and RoleAuthority.within?(authority, [role])) do
          change.(role, subject_id)
        end
      end)
    end
  end

  defp visible_subject(scope, subject_id) do
    if Visibility.member(scope) && active_member?(subject_id),
      do: :ok,
      else: {:error, :not_found}
  end

  defp refusal(scope, role_id) do
    if Visibility.member(scope) && Repo.exists?(from(role in Role, where: role.id == ^role_id)),
      do: {:error, :forbidden},
      else: {:error, :not_found}
  end

  defp lock_role(role_id) do
    case Repo.one(from(role in Role, where: role.id == ^role_id, lock: "FOR UPDATE")) do
      %Role{} = role -> {:ok, role}
      nil -> {:error, :not_found}
    end
  end

  defp record_audit_log!(%Scope{user_id: actor_id}, action_type, %Role{} = role, subject_id) do
    %AuditLogEntry{}
    |> AuditLogEntry.changeset(%{
      action_type: action_type,
      actor_user_id: actor_id,
      subject_user_id: subject_id,
      target_type: "role",
      target_id: role.id,
      metadata: %{
        "role_name" => role.name,
        "permissions" => role.permissions,
        "position" => role.position
      }
    })
    |> Repo.insert!()
  end

  # --- Helpers -----------------------------------------------------------------------------------

  # The default role keeps its place and is never deleted; a managed role is the system's.
  defp changeable?(%Role{is_default: false, managed: false}), do: true
  defp changeable?(%Role{}), do: false

  # Only its permissions are editable on the default role, which bootstrap marks managed.
  defp editable?(%Role{is_default: true}), do: true
  defp editable?(%Role{} = role), do: changeable?(role)

  defp permit(true), do: :ok
  defp permit(false), do: {:error, :forbidden}

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp direction_delta(direction) when direction in [:up, "up"], do: {:ok, -1}
  defp direction_delta(direction) when direction in [:down, "down"], do: {:ok, 1}
  defp direction_delta(_direction), do: {:error, :not_found}

  defp active_member?(user_id) do
    Repo.exists?(
      from(membership in Membership,
        join: user in User,
        on: user.id == membership.user_id,
        where:
          membership.user_id == ^user_id and is_nil(membership.deactivated_at) and
            is_nil(user.deleted_at)
      )
    )
  end

  # All roles, highest first: non-default roles by position, then the default role last.
  defp ordered_roles do
    from(role in Role, order_by: [asc: role.is_default, desc: role.position, asc: role.name])
    |> Repo.all()
  end

  # The non-default roles, highest first, without `except_id`.
  defp ranked_roles(except_id \\ nil) do
    Enum.reject(ordered_roles(), &(&1.is_default or &1.id == except_id))
  end

  # Writes positions n..1 to `roles`, in order, skipping rows already there.
  defp renumber!(roles) do
    count = length(roles)

    roles
    |> Enum.with_index()
    |> Enum.each(fn {role, index} ->
      position = count - index

      if role.position != position do
        from(row in Role, where: row.id == ^role.id)
        |> Repo.update_all(set: [position: position, updated_at: DateTime.utc_now()])
      end
    end)
  end

  defp member_counts do
    active =
      from(membership in Membership,
        join: user in User,
        on: user.id == membership.user_id,
        where: is_nil(membership.deactivated_at) and is_nil(user.deleted_at)
      )

    by_role =
      from([membership, _user] in active,
        join: member_role in MemberRole,
        on: member_role.user_id == membership.user_id,
        group_by: member_role.role_id,
        select: {member_role.role_id, count(member_role.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{all: Repo.aggregate(active, :count), by_role: by_role}
  end
end
