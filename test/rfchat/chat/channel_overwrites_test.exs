defmodule Rfchat.Chat.ChannelOverwritesTest do
  use Rfchat.DataCase, async: false

  import Rfchat.ChatFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.AuditLogEntry
  alias Rfchat.Chat.ChannelPermissionOverwrite
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.Topics

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    channel = channel_fixture(%{name: "Lounge"})

    manager_role =
      role_fixture(%{
        name: "Manager",
        position: 50,
        permissions: bits([:view_channel, :send_messages, :manage_roles])
      })

    low_role = role_fixture(%{name: "Low", position: 10})
    high_role = role_fixture(%{name: "High", position: 80})

    manager = user_fixture()
    member_role_fixture(manager, manager_role)
    member = user_fixture()

    %{
      owner: owner,
      channel: channel,
      manager: manager,
      member: member,
      manager_role: manager_role,
      low_role: low_role,
      high_role: high_role,
      everyone: Chat.default_role()
    }
  end

  defp bits(names), do: PermissionBits.combine(names)

  defp overwrite_for(channel, role_id) do
    Repo.get_by(ChannelPermissionOverwrite, channel_id: channel.id, role_id: role_id)
  end

  # Broadcasts skip the writing process, so a separate subscriber forwards guild events here.
  defp forward_guild_events do
    parent = self()

    spawn_link(fn ->
      Topics.subscribe_guild()
      send(parent, :subscribed)
      forward(parent)
    end)

    assert_receive :subscribed
  end

  defp forward(parent) do
    receive do
      event ->
        send(parent, {:guild_event, event})
        forward(parent)
    end
  end

  describe "put_overwrite/5" do
    test "the owner makes a channel private to one role", ctx do
      member_with_role = user_fixture()
      member_role_fixture(member_with_role, ctx.low_role)
      forward_guild_events()

      assert {:ok, _} =
               Chat.put_overwrite(
                 scope_for(ctx.owner),
                 ctx.channel.id,
                 {:role, ctx.everyone.id},
                 0,
                 bits([:view_channel])
               )

      assert {:ok, _} =
               Chat.put_overwrite(
                 scope_for(ctx.owner),
                 ctx.channel.id,
                 {:role, ctx.low_role.id},
                 bits([:view_channel]),
                 0
               )

      assert is_nil(Chat.get_channel(scope_for(ctx.member), ctx.channel.id))
      assert Chat.get_channel(scope_for(member_with_role), ctx.channel.id)
      assert_receive {:guild_event, :roles_changed}

      assert [entry | _] =
               Repo.all(
                 from(entry in AuditLogEntry,
                   where: entry.action_type == "channel_overwrite_updated",
                   order_by: [desc: entry.inserted_at]
                 )
               )

      assert entry.channel_id == ctx.channel.id
      assert entry.metadata["role_id"] == ctx.low_role.id
      assert entry.metadata["allow"] == bits([:view_channel])
    end

    test "storing the same bits again changes nothing", ctx do
      scope = scope_for(ctx.owner)
      target = {:role, ctx.low_role.id}
      {:ok, _} = Chat.put_overwrite(scope, ctx.channel.id, target, bits([:send_messages]), 0)
      count = Repo.aggregate(AuditLogEntry, :count)

      assert {:ok, _} =
               Chat.put_overwrite(scope, ctx.channel.id, target, bits([:send_messages]), 0)

      assert Repo.aggregate(AuditLogEntry, :count) == count
    end

    test "a user target sets the user's overwrite", ctx do
      {:ok, overwrite} =
        Chat.put_overwrite(
          scope_for(ctx.owner),
          ctx.channel.id,
          {:user, ctx.member.id},
          0,
          bits([:send_messages])
        )

      assert overwrite.user_id == ctx.member.id
      refute Rfchat.Chat.Visibility.can?(scope_for(ctx.member), :send_messages, ctx.channel)
    end

    test "a manager changes only bits it holds in the channel", ctx do
      scope = scope_for(ctx.manager)
      target = {:role, ctx.low_role.id}

      assert {:ok, _} =
               Chat.put_overwrite(scope, ctx.channel.id, target, bits([:send_messages]), 0)

      assert {:error, :forbidden} =
               Chat.put_overwrite(scope, ctx.channel.id, target, bits([:kick_members]), 0)

      assert {:error, :forbidden} =
               Chat.put_overwrite(scope, ctx.channel.id, target, 0, bits([:manage_messages]))
    end

    test "a manager keeps a bit it does not hold that is already stored", ctx do
      {:ok, _} =
        Chat.put_overwrite(
          scope_for(ctx.owner),
          ctx.channel.id,
          {:role, ctx.low_role.id},
          bits([:manage_messages]),
          0
        )

      scope = scope_for(ctx.manager)
      target = {:role, ctx.low_role.id}

      assert {:ok, overwrite} =
               Chat.put_overwrite(
                 scope,
                 ctx.channel.id,
                 target,
                 bits([:manage_messages, :send_messages]),
                 0
               )

      assert overwrite.allow_permissions == bits([:manage_messages, :send_messages])

      assert {:error, :forbidden} =
               Chat.put_overwrite(scope, ctx.channel.id, target, bits([:send_messages]), 0)

      assert {:error, :forbidden} = Chat.delete_overwrite(scope, ctx.channel.id, target)
    end

    test "manage_roles counts after the channel's overwrites", ctx do
      {:ok, _} =
        Chat.put_overwrite(
          scope_for(ctx.owner),
          ctx.channel.id,
          {:role, ctx.manager_role.id},
          0,
          bits([:manage_roles])
        )

      assert {:error, :forbidden} =
               Chat.put_overwrite(
                 scope_for(ctx.manager),
                 ctx.channel.id,
                 {:role, ctx.low_role.id},
                 bits([:send_messages]),
                 0
               )

      other = channel_fixture(%{name: "Other"})

      assert {:ok, _} =
               Chat.put_overwrite(
                 scope_for(ctx.manager),
                 other.id,
                 {:role, ctx.low_role.id},
                 bits([:send_messages]),
                 0
               )
    end

    test "a member without manage_roles is refused", ctx do
      assert {:error, :forbidden} =
               Chat.put_overwrite(
                 scope_for(ctx.member),
                 ctx.channel.id,
                 {:role, ctx.everyone.id},
                 0,
                 bits([:send_messages])
               )
    end

    test "the administrator bit is never valid, even for the owner", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Chat.put_overwrite(
                 scope_for(ctx.owner),
                 ctx.channel.id,
                 {:role, ctx.low_role.id},
                 bits([:administrator]),
                 0
               )

      assert %{allow_permissions: ["cannot include administrator"]} = errors_on(changeset)
    end

    test "an administrator holds every channel bit but administrator", ctx do
      admin_role =
        role_fixture(%{name: "Admin", position: 70, permissions: bits([:administrator])})

      admin = user_fixture()
      member_role_fixture(admin, admin_role)

      assert {:ok, _} =
               Chat.put_overwrite(
                 scope_for(admin),
                 ctx.channel.id,
                 {:role, ctx.low_role.id},
                 bits([:kick_members, :manage_messages]),
                 0
               )

      assert %{changeable_bits: changeable} =
               Chat.overwrite_controls(scope_for(admin), ctx.channel.id)

      assert Bitwise.band(changeable, bits([:administrator])) == 0
      assert Bitwise.band(changeable, bits([:kick_members])) != 0
    end

    test "a bit cannot be allowed and denied at once", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Chat.put_overwrite(
                 scope_for(ctx.owner),
                 ctx.channel.id,
                 {:role, ctx.low_role.id},
                 bits([:send_messages]),
                 bits([:send_messages])
               )
    end

    test "a role target sits below the actor's top role", ctx do
      scope = scope_for(ctx.manager)

      for role <- [ctx.high_role, ctx.manager_role] do
        assert {:error, :forbidden} =
                 Chat.put_overwrite(
                   scope,
                   ctx.channel.id,
                   {:role, role.id},
                   bits([:send_messages]),
                   0
                 )
      end

      assert {:ok, _} =
               Chat.put_overwrite(
                 scope,
                 ctx.channel.id,
                 {:role, ctx.everyone.id},
                 bits([:send_messages]),
                 0
               )

      assert {:ok, _} =
               Chat.put_overwrite(
                 scope_for(ctx.owner),
                 ctx.channel.id,
                 {:role, ctx.high_role.id},
                 bits([:send_messages]),
                 0
               )
    end

    test "a member with no roles still targets the default role", ctx do
      everyone_manager = user_fixture()

      overwrite_role =
        role_fixture(%{name: "Grant", position: 5, permissions: 0})

      {:ok, _} =
        Chat.put_overwrite(
          scope_for(ctx.owner),
          ctx.channel.id,
          {:user, everyone_manager.id},
          bits([:manage_roles, :send_messages]),
          0
        )

      scope = scope_for(everyone_manager)

      assert {:ok, _} =
               Chat.put_overwrite(
                 scope,
                 ctx.channel.id,
                 {:role, ctx.everyone.id},
                 bits([:send_messages]),
                 0
               )

      assert {:error, :forbidden} =
               Chat.put_overwrite(
                 scope,
                 ctx.channel.id,
                 {:role, overwrite_role.id},
                 bits([:send_messages]),
                 0
               )
    end

    test "a user target is the actor or a member ranked below it", ctx do
      scope = scope_for(ctx.manager)
      peer = user_fixture()
      member_role_fixture(peer, ctx.manager_role)
      senior = user_fixture()
      member_role_fixture(senior, ctx.high_role)

      for user <- [ctx.manager, ctx.member] do
        assert {:ok, _} =
                 Chat.put_overwrite(
                   scope,
                   ctx.channel.id,
                   {:user, user.id},
                   bits([:send_messages]),
                   0
                 )
      end

      for user <- [peer, senior, ctx.owner] do
        assert {:error, :forbidden} =
                 Chat.put_overwrite(
                   scope,
                   ctx.channel.id,
                   {:user, user.id},
                   bits([:send_messages]),
                   0
                 )
      end
    end

    test "only an owner targets an owner", ctx do
      second_owner = owner_fixture()

      assert {:ok, _} =
               Chat.put_overwrite(
                 scope_for(ctx.owner),
                 ctx.channel.id,
                 {:user, second_owner.id},
                 bits([:send_messages]),
                 0
               )
    end

    test "a hidden or missing channel answers not_found", ctx do
      hidden = channel_fixture(%{name: "Hidden"})

      channel_permission_overwrite_fixture(hidden, %{
        role_id: ctx.manager_role.id,
        deny_permissions: bits([:view_channel])
      })

      for channel_id <- [hidden.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :not_found} =
                 Chat.put_overwrite(
                   scope_for(ctx.manager),
                   channel_id,
                   {:role, ctx.low_role.id},
                   bits([:send_messages]),
                   0
                 )

        assert {:error, :not_found} = Chat.list_overwrites(scope_for(ctx.manager), channel_id)
      end
    end

    test "a missing role or a member who left answers not_found", ctx do
      gone = user_fixture()

      from(membership in Rfchat.Chat.Membership, where: membership.user_id == ^gone.id)
      |> Repo.update_all(set: [deactivated_at: DateTime.utc_now()])

      for target <- [
            {:role, Ecto.UUID.generate()},
            {:user, gone.id},
            {:user, Ecto.UUID.generate()}
          ] do
        assert {:error, :not_found} =
                 Chat.put_overwrite(scope_for(ctx.owner), ctx.channel.id, target, 0, 0)
      end
    end

    test "a thread takes no managed overwrites", ctx do
      message = message_fixture(ctx.channel, ctx.owner)
      thread = thread_fixture(ctx.channel, message, ctx.owner, %{name: "Thread"})

      assert {:error, :thread} =
               Chat.put_overwrite(
                 scope_for(ctx.owner),
                 thread.id,
                 {:role, ctx.low_role.id},
                 bits([:send_messages]),
                 0
               )
    end

    test "a category overwrite applies to the category", ctx do
      {:ok, category} =
        Chat.create_channel(scope_for(ctx.owner), %{
          "name" => "Staff",
          "slug" => unique_slug(),
          "kind" => "category"
        })

      assert {:ok, _} =
               Chat.put_overwrite(
                 scope_for(ctx.owner),
                 category.id,
                 {:role, ctx.everyone.id},
                 0,
                 bits([:view_channel])
               )

      assert is_nil(Chat.get_channel(scope_for(ctx.member), category.id))
      assert Chat.get_channel(scope_for(ctx.member), ctx.channel.id)
    end
  end

  describe "delete_overwrite/3" do
    test "removes the overwrite and records it", ctx do
      scope = scope_for(ctx.owner)
      target = {:role, ctx.low_role.id}
      {:ok, _} = Chat.put_overwrite(scope, ctx.channel.id, target, bits([:send_messages]), 0)

      assert {:ok, _} = Chat.delete_overwrite(scope, ctx.channel.id, target)
      assert is_nil(overwrite_for(ctx.channel, ctx.low_role.id))

      assert Repo.exists?(
               from(entry in AuditLogEntry,
                 where: entry.action_type == "channel_overwrite_deleted"
               )
             )

      assert {:error, :not_found} = Chat.delete_overwrite(scope, ctx.channel.id, target)
    end
  end

  describe "list_overwrites/2 and overwrite_controls/2" do
    test "lists the default role first, then roles, then users", ctx do
      scope = scope_for(ctx.owner)
      {:ok, _} = Chat.put_overwrite(scope, ctx.channel.id, {:user, ctx.member.id}, 0, 0)
      {:ok, _} = Chat.put_overwrite(scope, ctx.channel.id, {:role, ctx.low_role.id}, 0, 0)
      {:ok, _} = Chat.put_overwrite(scope, ctx.channel.id, {:role, ctx.high_role.id}, 0, 0)
      {:ok, _} = Chat.put_overwrite(scope, ctx.channel.id, {:role, ctx.everyone.id}, 0, 0)

      assert {:ok, overwrites} = Chat.list_overwrites(scope, ctx.channel.id)

      assert Enum.map(overwrites, &(&1.role_id || &1.user_id)) == [
               ctx.everyone.id,
               ctx.high_role.id,
               ctx.low_role.id,
               ctx.member.id
             ]
    end

    test "a member without manage_roles reads nothing and may change nothing", ctx do
      assert {:error, :forbidden} = Chat.list_overwrites(scope_for(ctx.member), ctx.channel.id)

      assert %{changeable_bits: 0} =
               Chat.overwrite_controls(scope_for(ctx.member), ctx.channel.id)
    end

    test "the controls name the targets a manager ranks over", ctx do
      controls = Chat.overwrite_controls(scope_for(ctx.manager), ctx.channel.id)

      assert MapSet.member?(controls.role_ids, ctx.everyone.id)
      assert MapSet.member?(controls.role_ids, ctx.low_role.id)
      refute MapSet.member?(controls.role_ids, ctx.manager_role.id)
      assert MapSet.member?(controls.user_ids, ctx.manager.id)
      assert MapSet.member?(controls.user_ids, ctx.member.id)
      refute MapSet.member?(controls.user_ids, ctx.owner.id)
      assert Bitwise.band(controls.changeable_bits, bits([:manage_roles])) != 0
      assert Bitwise.band(controls.changeable_bits, bits([:kick_members])) == 0
    end
  end
end
