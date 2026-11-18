defmodule Rfchat.Chat.RolesTest do
  use Rfchat.DataCase, async: false

  import Rfchat.ChatFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.AuditLogEntry
  alias Rfchat.Chat.MemberRole
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.Role

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()

    manager_role =
      role_fixture(%{
        name: "Manager",
        position: 50,
        permissions: PermissionBits.combine([:view_channel, :send_messages, :manage_roles])
      })

    low_role =
      role_fixture(%{
        name: "Low",
        position: 10,
        permissions: PermissionBits.combine([:send_messages])
      })

    manager = user_fixture()
    member_role_fixture(manager, manager_role)
    member = user_fixture()

    %{
      owner: owner,
      manager: manager,
      member: member,
      manager_role: manager_role,
      low_role: low_role
    }
  end

  defp bits(names), do: PermissionBits.combine(names)

  defp role_ids(user) do
    Repo.all(
      from(member_role in MemberRole,
        where: member_role.user_id == ^user.id,
        select: member_role.role_id
      )
    )
  end

  defp remove_member!(user) do
    from(membership in Rfchat.Chat.Membership, where: membership.user_id == ^user.id)
    |> Repo.update_all(set: [deactivated_at: DateTime.utc_now()])
  end

  describe "list_roles/1" do
    test "lists roles highest first, default last, with active member counts", ctx do
      member_role_fixture(ctx.member, ctx.low_role)

      roles = Chat.list_roles(scope_for(ctx.member))
      names = Enum.map(roles, & &1.name)

      assert Enum.take(names, 2) == ["Manager", "Low"]
      assert List.last(roles).is_default
      assert Enum.find(roles, &(&1.id == ctx.low_role.id)).member_count == 1
    end
  end

  describe "create_role/2" do
    test "a manager creates a role just above the default role and it is audited", ctx do
      assert {:ok, role} =
               Chat.create_role(scope_for(ctx.manager), %{
                 "name" => "Helpers",
                 "permissions" => bits([:send_messages])
               })

      ordered = Chat.list_roles(scope_for(ctx.manager)) |> Enum.map(& &1.name)
      assert ordered == ["Manager", "Low", "Helpers", "@everyone"]
      assert role.position == 1

      positions = Repo.all(from(r in Role, where: not r.is_default, select: r.position))
      assert Enum.sort(positions) == Enum.uniq(Enum.sort(positions))

      assert %AuditLogEntry{actor_user_id: actor_id, target_type: "role"} =
               Repo.get_by!(AuditLogEntry, action_type: "role_created", target_id: role.id)

      assert actor_id == ctx.manager.id
    end

    test "a member without manage_roles is refused", ctx do
      assert {:error, :forbidden} = Chat.create_role(scope_for(ctx.member), %{"name" => "X"})
    end

    test "a manager cannot put a bit they do not hold on a role", ctx do
      assert {:error, :forbidden} =
               Chat.create_role(scope_for(ctx.manager), %{
                 "name" => "Banners",
                 "permissions" => bits([:ban_members])
               })
    end

    test "only the owner sets administrator", ctx do
      admin_role = role_fixture(%{position: 60, permissions: bits([:administrator])})
      admin = user_fixture()
      member_role_fixture(admin, admin_role)

      attrs = %{"name" => "Admins", "permissions" => bits([:administrator])}

      assert {:error, :forbidden} = Chat.create_role(scope_for(admin), attrs)

      assert {:ok, _role} =
               Chat.create_role(scope_for(admin), %{attrs | "permissions" => bits([:ban_members])})

      assert {:ok, %Role{}} = Chat.create_role(scope_for(ctx.owner), attrs)
    end
  end

  describe "update_role/3" do
    test "a manager edits a lower role within their bits", ctx do
      assert {:ok, role} =
               Chat.update_role(scope_for(ctx.manager), ctx.low_role.id, %{
                 "name" => "Lower",
                 "permissions" => bits([:send_messages, :view_channel])
               })

      assert role.name == "Lower"
      assert Repo.get_by(AuditLogEntry, action_type: "role_updated", target_id: role.id)
    end

    test "a role equal to or above the actor's top is refused", ctx do
      high = role_fixture(%{position: 70})

      assert {:error, :forbidden} =
               Chat.update_role(scope_for(ctx.manager), ctx.manager_role.id, %{"name" => "Me"})

      assert {:error, :forbidden} =
               Chat.update_role(scope_for(ctx.manager), high.id, %{"name" => "Up"})
    end

    test "adding a bit the actor lacks is refused", ctx do
      assert {:error, :forbidden} =
               Chat.update_role(scope_for(ctx.manager), ctx.low_role.id, %{
                 "permissions" => bits([:send_messages, :kick_members])
               })
    end

    test "a lower role holding a bit the actor lacks cannot be edited at all", ctx do
      kickers = role_fixture(%{position: 20, permissions: bits([:kick_members])})

      assert {:error, :forbidden} =
               Chat.update_role(scope_for(ctx.manager), kickers.id, %{
                 "name" => "Renamed",
                 "permissions" => 0
               })

      assert Repo.get!(Role, kickers.id).permissions == bits([:kick_members])
    end

    test "an edit to the default role's permissions survives the next bootstrap", ctx do
      default = Chat.default_role()
      edited = bits([:view_channel, :send_messages, :add_reactions])

      assert {:ok, _} =
               Chat.update_role(scope_for(ctx.owner), default.id, %{"permissions" => edited})

      Bootstrap.ensure_seed_data!()
      assert Repo.get!(Role, default.id).permissions == edited
    end

    test "the default role takes only permission edits", ctx do
      default = Chat.default_role()

      assert {:ok, role} =
               Chat.update_role(scope_for(ctx.owner), default.id, %{
                 "name" => "@nobody",
                 "permissions" => bits([:view_channel])
               })

      assert role.name == "@everyone"
      assert role.permissions == bits([:view_channel])
    end

    test "a managed role that is not the default is refused, even for the owner", ctx do
      managed = role_fixture(%{position: 5, managed: true})

      assert {:error, :forbidden} =
               Chat.update_role(scope_for(ctx.owner), managed.id, %{"name" => "Mine"})
    end

    test "a missing or malformed role is not found; a forbidden actor sees not found too", ctx do
      assert {:error, :not_found} =
               Chat.update_role(scope_for(ctx.manager), Ecto.UUID.generate(), %{"name" => "X"})

      assert {:error, :not_found} = Chat.update_role(scope_for(ctx.manager), "nope", %{})

      assert {:error, :not_found} =
               Chat.update_role(scope_for(ctx.member), Ecto.UUID.generate(), %{"name" => "X"})

      assert {:error, :forbidden} =
               Chat.update_role(scope_for(ctx.member), ctx.low_role.id, %{"name" => "X"})
    end
  end

  describe "move_role/3" do
    test "a manager swaps two roles below them", ctx do
      middle = role_fixture(%{name: "Middle", position: 30})

      assert {:ok, _} = Chat.move_role(scope_for(ctx.manager), ctx.low_role.id, :up)

      names = Chat.list_roles(scope_for(ctx.manager)) |> Enum.map(& &1.name)
      assert names == ["Manager", "Low", "Middle", "@everyone"]
      assert Repo.get!(Role, middle.id).position < Repo.get!(Role, ctx.low_role.id).position
      assert Repo.get_by(AuditLogEntry, action_type: "role_moved", target_id: ctx.low_role.id)
    end

    test "a role cannot move into or past the actor's top role", ctx do
      assert {:error, :forbidden} = Chat.move_role(scope_for(ctx.manager), ctx.low_role.id, :up)
    end

    test "a move at the edge changes nothing and records nothing", ctx do
      assert {:ok, role} = Chat.move_role(scope_for(ctx.manager), ctx.low_role.id, :down)
      assert role.position == ctx.low_role.position
      refute Repo.get_by(AuditLogEntry, action_type: "role_moved")
    end

    test "the default role cannot move", ctx do
      assert {:error, :forbidden} =
               Chat.move_role(scope_for(ctx.owner), Chat.default_role().id, :up)
    end
  end

  describe "delete_role/2" do
    test "deletes the role with its member roles", ctx do
      member_role_fixture(ctx.member, ctx.low_role)

      assert {:ok, _} = Chat.delete_role(scope_for(ctx.manager), ctx.low_role.id)
      refute Repo.get(Role, ctx.low_role.id)
      refute Repo.get_by(MemberRole, role_id: ctx.low_role.id)
      assert Repo.get_by(AuditLogEntry, action_type: "role_deleted", target_id: ctx.low_role.id)
    end

    test "a manager deletes a lower role that denies them a channel, and then sees it", ctx do
      channel = channel_fixture(%{name: "Behind", slug: unique_slug()})

      channel_permission_overwrite_fixture(channel, %{
        role_id: ctx.low_role.id,
        deny_permissions: bits([:view_channel])
      })

      member_role_fixture(ctx.manager, ctx.low_role)
      scope = scope_for(ctx.manager)
      refute Chat.get_channel(scope, channel.id)

      assert {:ok, _} = Chat.delete_role(scope, ctx.low_role.id)
      assert Chat.get_channel(scope, channel.id)
    end

    test "the default role cannot be deleted", ctx do
      assert {:error, :forbidden} = Chat.delete_role(scope_for(ctx.owner), Chat.default_role().id)
    end
  end

  describe "add_member_role/3 and remove_member_role/3" do
    test "a manager gives and takes a lower role, audited with the subject", ctx do
      scope = scope_for(ctx.manager)

      assert {:ok, _} = Chat.add_member_role(scope, ctx.member.id, ctx.low_role.id)
      assert Enum.map(Chat.member_roles(scope, ctx.member.id), & &1.id) == [ctx.low_role.id]

      assert %AuditLogEntry{subject_user_id: subject_id} =
               Repo.get_by!(AuditLogEntry, action_type: "member_role_added")

      assert subject_id == ctx.member.id

      assert {:ok, _} = Chat.remove_member_role(scope, ctx.member.id, ctx.low_role.id)
      assert Chat.member_roles(scope, ctx.member.id) == []
      assert Repo.get_by(AuditLogEntry, action_type: "member_role_removed")
    end

    test "a role at or above the actor's top cannot be given", ctx do
      assert {:error, :forbidden} =
               Chat.add_member_role(scope_for(ctx.manager), ctx.member.id, ctx.manager_role.id)
    end

    test "a subject whose top role is at or above the actor's is refused", ctx do
      high = role_fixture(%{position: 70})
      member_role_fixture(ctx.member, high)
      peer = user_fixture()
      member_role_fixture(peer, ctx.manager_role)

      for subject <- [ctx.member, peer, ctx.owner] do
        assert {:error, :forbidden} =
                 Chat.add_member_role(scope_for(ctx.manager), subject.id, ctx.low_role.id)
      end
    end

    test "a manager gives and takes a role below their top from themselves", ctx do
      scope = scope_for(ctx.manager)

      assert {:ok, _} = Chat.add_member_role(scope, ctx.manager.id, ctx.low_role.id)
      assert ctx.low_role.id in role_ids(ctx.manager)
      assert {:ok, _} = Chat.remove_member_role(scope, ctx.manager.id, ctx.low_role.id)
      refute ctx.low_role.id in role_ids(ctx.manager)
    end

    test "a manager cannot give themselves a role at or above their top", ctx do
      high = role_fixture(%{position: 70})

      for role <- [ctx.manager_role, high] do
        assert {:error, :forbidden} =
                 Chat.add_member_role(scope_for(ctx.manager), ctx.manager.id, role.id)
      end
    end

    test "the owner gives and takes any givable role, themselves included", ctx do
      scope = scope_for(ctx.owner)

      assert {:ok, _} = Chat.add_member_role(scope, ctx.owner.id, ctx.manager_role.id)
      assert ctx.manager_role.id in role_ids(ctx.owner)
      assert {:ok, _} = Chat.add_member_role(scope, ctx.manager.id, ctx.low_role.id)
      assert {:ok, _} = Chat.remove_member_role(scope, ctx.owner.id, ctx.manager_role.id)
      refute ctx.manager_role.id in role_ids(ctx.owner)
    end

    test "the default role is never given or taken", ctx do
      default = Chat.default_role()

      assert {:error, :forbidden} =
               Chat.add_member_role(scope_for(ctx.owner), ctx.member.id, default.id)

      assert {:error, :forbidden} =
               Chat.remove_member_role(scope_for(ctx.owner), ctx.member.id, default.id)
    end

    test "a member without manage_roles is refused", ctx do
      other = user_fixture()

      assert {:error, :forbidden} =
               Chat.add_member_role(scope_for(ctx.member), other.id, ctx.low_role.id)
    end

    test "a missing member or role is not found", ctx do
      scope = scope_for(ctx.manager)

      assert {:error, :not_found} =
               Chat.add_member_role(scope, Ecto.UUID.generate(), ctx.low_role.id)

      assert {:error, :not_found} = Chat.add_member_role(scope, "nope", ctx.low_role.id)

      assert {:error, :not_found} =
               Chat.add_member_role(scope, ctx.member.id, Ecto.UUID.generate())
    end

    test "a removed subject is not found, whether below or above the actor", ctx do
      high = role_fixture(%{position: 70})
      above = user_fixture()
      member_role_fixture(above, high)
      remove_member!(ctx.member)
      remove_member!(above)

      for subject <- [ctx.member, above] do
        assert {:error, :not_found} =
                 Chat.add_member_role(scope_for(ctx.manager), subject.id, ctx.low_role.id)
      end
    end

    test "a removed actor gets not found for an existing role and member", ctx do
      remove_member!(ctx.manager)
      scope = scope_for(ctx.manager)

      assert {:error, :not_found} = Chat.add_member_role(scope, ctx.member.id, ctx.low_role.id)
      assert {:error, :not_found} = Chat.update_role(scope, ctx.low_role.id, %{"name" => "X"})
      assert {:error, :not_found} = Chat.delete_role(scope, ctx.low_role.id)
    end

    test "giving a held role or taking one not held records nothing", ctx do
      scope = scope_for(ctx.manager)
      member_role_fixture(ctx.member, ctx.low_role)

      assert {:ok, _} = Chat.add_member_role(scope, ctx.member.id, ctx.low_role.id)
      assert {:ok, _} = Chat.remove_member_role(scope, ctx.member.id, ctx.low_role.id)
      assert {:ok, _} = Chat.remove_member_role(scope, ctx.member.id, ctx.low_role.id)

      action_types = Repo.all(from(entry in AuditLogEntry, select: entry.action_type))
      assert action_types == ["member_role_removed"]
    end

    test "a role with an overwrite unlocking a channel the actor cannot use is refused", ctx do
      private =
        channel_fixture(%{name: "Private", slug: unique_slug()})

      channel_permission_overwrite_fixture(private, %{
        role_id: Chat.default_role().id,
        deny_permissions: bits([:view_channel]),
        allow_permissions: 0
      })

      channel_permission_overwrite_fixture(private, %{
        role_id: ctx.low_role.id,
        allow_permissions: bits([:view_channel]),
        deny_permissions: 0
      })

      assert {:error, :forbidden} =
               Chat.add_member_role(scope_for(ctx.manager), ctx.member.id, ctx.low_role.id)
    end
  end
end
