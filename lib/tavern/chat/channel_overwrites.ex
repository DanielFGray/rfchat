defmodule Tavern.Chat.ChannelOverwrites do
  @moduledoc """
  Channel and category permission overwrites: list them, and put or delete the overwrite for one
  role or one user. Every function takes a `%Scope{}` first; every write decides inside its own
  transaction.

  An actor may write an overwrite when (docs/design/roles.md, "Channel overwrites"):

  - it can view the channel and holds `manage_roles` in it, after overwrites;
  - every bit the write changes, in allow or in deny, is a bit it holds in that channel;
  - the target is a role below its top role (the default role always), or itself, or a member
    whose top role is below its own. Only an owner targets an owner.

  The owner passes every rule. An administrator holds every bit in every channel, except that only
  the owner changes the `administrator` bit; no overwrite may set it
  (`ChannelPermissionOverwrite.changeset/2`).

  A write takes its locks in this order (docs/design/scoped-reads.md, "Consistency"): the role-list
  lock, the channel-tree lock, the membership rows (the actor's, and for a user target the
  subject's too), then the channel row, then the overwrite row. An overwrite changes what role
  writes and channel writes both decide from, so it is serialized against both.

  A hidden or missing channel, a missing role, a put for a user who is not an active member, and a
  delete of an overwrite that does not exist answer `{:error, :not_found}`. A visible channel the
  actor may not change answers `{:error, :forbidden}`; a thread answers `{:error, :thread}`. A
  write that changes something records an audit log entry and broadcasts `:roles_changed` after it
  commits, so every open view recomputes the channels it shows and what it may manage.
  """

  import Bitwise
  import Ecto.Query, warn: false

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.Channel
  alias Tavern.Chat.ChannelPermissionOverwrite
  alias Tavern.Chat.Channels
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.Membership
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Role
  alias Tavern.Chat.Topics
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @administrator PermissionBits.flag(:administrator)

  @doc """
  The overwrites on a channel or category, with `role` or `user` loaded: the default role's first,
  then roles highest first, then users by name. Only a scope that may manage the channel's
  permissions reads them.
  """
  def list_overwrites(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- cast_id(channel_id),
         :ok <- authorize_read(scope, channel_id) do
      overwrites =
        from(overwrite in ChannelPermissionOverwrite,
          where: overwrite.channel_id == ^channel_id,
          preload: [:role, :user]
        )
        |> Repo.all()
        |> Enum.sort_by(&sort_key/1)

      {:ok, overwrites}
    end
  end

  @doc """
  What the scope may change on a channel's overwrites, for the settings screen to decide what to
  show: `changeable_bits`, `role_ids` (roles it may target) and `user_ids` (active members it may
  target). A scope that may not manage the channel's permissions may change nothing. Writes decide
  again on their own.
  """
  def overwrite_controls(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- cast_id(channel_id),
         :ok <- authorize_read(scope, channel_id) do
      facts = Visibility.authority(scope, [channel_id])

      %{
        changeable_bits: changeable_bits(facts, channel_id),
        role_ids: target_role_ids(facts),
        user_ids: target_user_ids(scope, facts)
      }
    else
      _refused -> %{changeable_bits: 0, role_ids: MapSet.new(), user_ids: MapSet.new()}
    end
  end

  @doc """
  Sets the overwrite for `target` (`{:role, role_id}` or `{:user, user_id}`) on a channel or
  category to `allow` and `deny`, creating it when missing. An overwrite that allows and denies
  nothing is kept: it lists the target with every bit inherited.
  """
  def put_overwrite(%Scope{} = scope, channel_id, target, allow, deny),
    do: write(scope, channel_id, target, {allow, deny})

  @doc "Removes the overwrite for `target` from a channel or category."
  def delete_overwrite(%Scope{} = scope, channel_id, target),
    do: write(scope, channel_id, target, :delete)

  # --- Transactions ------------------------------------------------------------------------------

  # `desired` is the `{allow, deny}` to store, or `:delete`. The decision takes its locks before
  # the target is checked, so the check reads a target no other overwrite or role write can change.
  defp write(scope, channel_id, target, desired) do
    with {:ok, channel_id} <- cast_id(channel_id),
         {:ok, target} <- cast_target(target) do
      Repo.transact(fn ->
        Visibility.lock_role_list!()
        Channels.lock_channel_tree!()

        decision =
          Visibility.authorize_write(
            scope,
            {:manage_permissions, target},
            %Channel{id: channel_id}
          )

        with :ok <- present_target(desired, target),
             :ok <- decision,
             {:ok, channel} <- lock_channel(channel_id),
             existing = lock_overwrite(channel.id, target),
             {:ok, change} <- plan(desired, channel, target, existing),
             :ok <- permit_bits(scope, channel, bits(existing), bits(desired)) do
          persist(scope, channel, target, existing, desired, change)
        end
      end)
      |> case do
        {:ok, {:changed, overwrite}} ->
          Topics.broadcast_guild(:roles_changed)
          {:ok, overwrite}

        {:ok, {:unchanged, overwrite}} ->
          {:ok, overwrite}

        error ->
          error
      end
    end
  end

  # A put validates its changeset before any bit is weighed; a delete needs a stored overwrite.
  defp plan(:delete, _channel, _target, nil), do: {:error, :not_found}
  defp plan(:delete, _channel, _target, existing), do: {:ok, existing}

  defp plan({allow, deny}, channel, target, existing) do
    changeset =
      (existing || %ChannelPermissionOverwrite{channel_id: channel.id})
      |> ChannelPermissionOverwrite.changeset(
        Map.merge(target_attrs(target), %{allow_permissions: allow, deny_permissions: deny})
      )

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  # Every bit the write changes, in allow or in deny, is a bit the actor holds in the channel.
  defp permit_bits(scope, channel, before, after_write) do
    facts = Visibility.authority(scope, [channel.id])

    if band(changed_bits(before, after_write), bnot(changeable_bits(facts, channel.id))) == 0,
      do: :ok,
      else: {:error, :forbidden}
  end

  # A put that stores the bits already stored changes nothing, and is neither audited nor
  # broadcast. Creating an overwrite with no bits still adds a target, so it is a change.
  defp persist(scope, channel, target, existing, desired, change) do
    if existing && bits(existing) == desired do
      {:ok, {:unchanged, existing}}
    else
      result =
        case desired do
          :delete -> Repo.delete(change)
          {_allow, _deny} -> Repo.insert_or_update(change)
        end

      with {:ok, overwrite} <- result do
        record_audit_log!(scope, channel, target, desired, bits(existing))
        {:ok, {:changed, overwrite}}
      end
    end
  end

  defp authorize_read(scope, channel_id) do
    cond do
      Visibility.can?(scope, :manage_permissions, %Channel{id: channel_id}) -> :ok
      Visibility.visible_channel(scope, channel_id) -> {:error, :forbidden}
      true -> {:error, :not_found}
    end
  end

  # A put names a role that exists or an active member. A delete names a stored overwrite, which
  # `plan/4` checks once the channel row is held.
  defp present_target({_allow, _deny}, {:role, role_id}) do
    if Repo.exists?(from(role in Role, where: role.id == ^role_id)),
      do: :ok,
      else: {:error, :not_found}
  end

  defp present_target({_allow, _deny}, {:user, user_id}) do
    if Visibility.member(%Scope{user_id: user_id}), do: :ok, else: {:error, :not_found}
  end

  defp present_target(:delete, _target), do: :ok

  # Threads take no managed overwrites: they follow their parent channel.
  defp lock_channel(channel_id) do
    case Channels.lock_channel(channel_id) do
      %Channel{} = channel ->
        if Channel.thread?(channel), do: {:error, :thread}, else: {:ok, channel}

      nil ->
        {:error, :not_found}
    end
  end

  defp lock_overwrite(channel_id, target) do
    from(overwrite in ChannelPermissionOverwrite,
      where: overwrite.channel_id == ^channel_id,
      lock: "FOR UPDATE"
    )
    |> where_target(target)
    |> Repo.one()
  end

  defp where_target(query, {:role, role_id}),
    do: where(query, [overwrite], overwrite.role_id == ^role_id)

  defp where_target(query, {:user, user_id}),
    do: where(query, [overwrite], overwrite.user_id == ^user_id)

  defp record_audit_log!(%Scope{user_id: actor_id}, channel, target, desired, before) do
    {allow, deny} = bits(desired)
    {previous_allow, previous_deny} = before

    action_type =
      if desired == :delete, do: "channel_overwrite_deleted", else: "channel_overwrite_updated"

    %AuditLogEntry{}
    |> AuditLogEntry.changeset(%{
      action_type: action_type,
      actor_user_id: actor_id,
      subject_user_id: target_id(target, :user),
      channel_id: channel.id,
      target_type: "channel",
      target_id: channel.id,
      metadata: %{
        "channel_name" => channel.name,
        "role_id" => target_id(target, :role),
        "allow" => allow,
        "deny" => deny,
        "previous_allow" => previous_allow,
        "previous_deny" => previous_deny
      }
    })
    |> Repo.insert!()
  end

  # --- Helpers -----------------------------------------------------------------------------------

  # The bits the actor holds in the channel. An administrator holds every bit there, but only the
  # owner changes `administrator`.
  defp changeable_bits(%{owner?: true} = facts, channel_id),
    do: Map.get(facts.channel_permissions, channel_id, 0)

  defp changeable_bits(facts, channel_id),
    do: band(Map.get(facts.channel_permissions, channel_id, 0), bnot(@administrator))

  defp target_role_ids(%{owner?: owner?, top_role_position: top}) do
    from(role in Role,
      where: role.is_default or ^owner? or role.position < ^top,
      select: role.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # The active members the actor ranks over, by the rule `Visibility` decides a write with.
  defp target_user_ids(%Scope{user_id: actor_id}, facts) do
    from(membership in Membership,
      join: user in User,
      on: user.id == membership.user_id,
      left_join: member_role in MemberRole,
      on: member_role.user_id == membership.user_id,
      left_join: role in Role,
      on: role.id == member_role.role_id,
      where: is_nil(membership.deactivated_at) and is_nil(user.deleted_at),
      group_by: [membership.user_id, membership.is_owner],
      select: {membership.user_id, membership.is_owner, max(role.position)}
    )
    |> Repo.all()
    |> Enum.filter(fn {user_id, owner?, top} ->
      facts.owner? or user_id == actor_id or
        (not owner? and (top || 0) < facts.top_role_position)
    end)
    |> MapSet.new(fn {user_id, _owner?, _top} -> user_id end)
  end

  defp bits(nil), do: {0, 0}
  defp bits(:delete), do: {0, 0}
  defp bits({allow, deny}), do: {allow, deny}

  defp bits(%ChannelPermissionOverwrite{} = overwrite),
    do: {overwrite.allow_permissions, overwrite.deny_permissions}

  defp changed_bits({allow, deny}, {new_allow, new_deny}),
    do: bxor(allow, new_allow) ||| bxor(deny, new_deny)

  defp target_attrs({:role, role_id}), do: %{role_id: role_id, user_id: nil}
  defp target_attrs({:user, user_id}), do: %{role_id: nil, user_id: user_id}

  defp target_id({kind, id}, kind), do: id
  defp target_id(_target, _kind), do: nil

  defp cast_target({kind, id}) when kind in [:role, :user] do
    with {:ok, id} <- cast_id(id), do: {:ok, {kind, id}}
  end

  defp cast_target(_target), do: {:error, :not_found}

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp sort_key(%ChannelPermissionOverwrite{role: %Role{} = role}),
    do: {0, if(role.is_default, do: 0, else: 1), -role.position, role.name}

  defp sort_key(%ChannelPermissionOverwrite{user: %User{} = user}),
    do: {1, 0, 0, String.downcase(user.display_name || user.username)}
end
