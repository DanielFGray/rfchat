defmodule Rfchat.BotsTest do
  use Rfchat.DataCase

  import Ecto.Query, only: [from: 2]
  import Rfchat.ChatFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Bots
  alias Rfchat.Chat
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Repo

  describe "bot tokens and command registry" do
    test "creates bot users with roles and one-time tokens" do
      actor = owner_fixture(%{email: "bot-owner@example.com", username: "bot_owner"})

      role =
        role_fixture(%{
          name: "Bot Speaker",
          permissions: PermissionBits.combine([:send_messages])
        })

      {:ok, bot_user} =
        Bots.create_bot(
          %{
            "display_name" => "Helper Bot",
            "username" => "helper_bot",
            "email" => "helper-bot@example.com",
            "role_ids" => [role.id]
          },
          actor
        )

      assert bot_user.bot
      assert Enum.any?(bot_user.member_roles, &(&1.role_id == role.id))

      {:ok, %{token: token}} = Bots.create_bot_token(bot_user, %{"label" => "primary"}, actor)
      assert {:ok, bot_scope} = Bots.get_bot_scope_by_token(token)
      assert bot_scope.user_id == bot_user.id
    end

    test "executes registered message command" do
      actor = owner_fixture(%{email: "bot-cmd-owner@example.com", username: "bot_cmd_owner"})

      role =
        role_fixture(%{
          name: "Bot Speaker",
          permissions: PermissionBits.combine([:view_channel, :send_messages])
        })

      channel = channel_fixture(%{name: "Bots", slug: unique_slug()})
      bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})

      {:ok, %{message: message}} =
        Bots.execute_command(
          "send_message",
          bot_scope_for(bot_user, actor),
          %{"channel_id" => channel.id, "body" => "hello from bot"}
        )

      assert message.body == "hello from bot"
      assert message.channel_id == channel.id
    end

    test "get_bot_user/1 does not return non-bot users" do
      user = user_fixture(%{email: "human@example.com", username: "human_user"})

      assert Bots.get_bot_user(user.id) == nil
    end

    test "send_message returns invalid_params for malformed channel ids" do
      actor =
        owner_fixture(%{email: "bot-bad-channel-owner@example.com", username: "bot_bad_owner"})

      bot_user = bot_fixture(actor)

      assert {:error, :invalid_params} =
               Bots.command_send_message(
                 bot_scope_for(bot_user, actor),
                 %{"channel_id" => "not-a-uuid", "body" => "hello"}
               )
    end
  end

  describe "bot authority" do
    setup do
      owner = owner_fixture()
      %{owner: owner}
    end

    test "a manage_bots-only member cannot give a bot an administrator role" do
      bot_manager = member_with([:manage_bots])
      admin_role = role_fixture(%{permissions: PermissionBits.combine([:administrator])})

      assert {:error, :forbidden} =
               Bots.create_bot(bot_attrs(%{"role_ids" => [admin_role.id]}), bot_manager)

      assert Bots.list_controllable_bot_users(bot_manager) == []
    end

    test "the system user is never a manageable bot", %{owner: owner} do
      %{system_user: system_user} = Bootstrap.ensure_seed_data!()

      refute Enum.any?(Bots.list_controllable_bot_users(owner), &(&1.id == system_user.id))
      assert Bots.get_bot_user(system_user.id) == nil
      assert_raise Ecto.NoResultsError, fn -> Bots.get_bot_user!(system_user.id) end
    end

    test "a manage_bots-only member cannot give a bot any role" do
      bot_manager = member_with([:manage_bots])
      speaker = role_fixture(%{permissions: 0, position: 0})

      assert {:error, :forbidden} =
               Bots.create_bot(bot_attrs(%{"role_ids" => [speaker.id]}), bot_manager)
    end

    test "a role manager can grant only lower roles whose permissions they hold" do
      manager = member_with([:manage_bots, :manage_roles, :send_messages], position: 50)
      lower = role_fixture(%{permissions: PermissionBits.combine([:send_messages]), position: 10})
      higher = role_fixture(%{permissions: 0, position: 60})
      stronger = role_fixture(%{permissions: PermissionBits.combine([:ban_members]), position: 5})

      assert {:ok, bot} = Bots.create_bot(bot_attrs(%{"role_ids" => [lower.id]}), manager)
      assert [%{role_id: role_id}] = bot.member_roles
      assert role_id == lower.id

      for role <- [higher, stronger] do
        assert {:error, :forbidden} =
                 Bots.create_bot(bot_attrs(%{"role_ids" => [role.id]}), manager)
      end

      assert Enum.map(Bots.grantable_roles(manager), & &1.id) == [lower.id]
    end

    test "a bot manager cannot mint a token for a bot that outranks them", %{owner: owner} do
      admin_role = role_fixture(%{permissions: PermissionBits.combine([:administrator])})
      admin_bot = bot_fixture(owner, %{"role_ids" => [admin_role.id]})
      bot_manager = member_with([:manage_bots])

      assert {:error, :forbidden} = Bots.create_bot_token(admin_bot, %{}, bot_manager)
      assert {:error, :forbidden} = Bots.revoke_bot(admin_bot, bot_manager)
      assert Bots.list_bot_tokens(admin_bot) == []
    end

    test "authority is read from the database, not from the actor struct" do
      manager_role = role_fixture(%{permissions: PermissionBits.combine([:manage_bots])})
      manager = user_fixture()
      member_role = member_role_fixture(manager, manager_role)
      stale_manager = Rfchat.Repo.preload(manager, [:membership, member_roles: :role])

      Rfchat.Repo.delete!(member_role)

      assert {:error, :forbidden} = Bots.create_bot(bot_attrs(), stale_manager)
    end

    test "updating a bot without role_ids keeps its roles", %{owner: owner} do
      role = role_fixture()
      bot = bot_fixture(owner, %{"role_ids" => [role.id]})

      assert {:ok, updated} = Bots.update_bot(bot, %{"display_name" => "Renamed"}, owner)
      assert updated.display_name == "Renamed"
      assert Enum.map(updated.member_roles, & &1.role_id) == [role.id]
    end

    test "a manager cannot grant or control a role that unlocks a private channel", %{
      owner: owner
    } do
      manager = member_with([:manage_bots, :manage_roles], position: 50)
      {private, insider} = private_channel_insider_role()

      assert {:error, :forbidden} =
               Bots.create_bot(bot_attrs(%{"role_ids" => [insider.id]}), manager)

      refute Enum.any?(Bots.grantable_roles(manager), &(&1.id == insider.id))

      bot = bot_fixture(owner, %{"role_ids" => [insider.id]})
      assert {:error, :forbidden} = Bots.create_bot_token(bot, %{}, manager)

      assert {:ok, _bot} = Bots.create_bot(bot_attrs(%{"role_ids" => [insider.id]}), owner)

      channel_permission_overwrite_fixture(private, %{
        user_id: manager.id,
        allow_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:ok, granted} = Bots.create_bot(bot_attrs(%{"role_ids" => [insider.id]}), manager)
      assert Enum.any?(granted.member_roles, &(&1.role_id == insider.id))
      assert Enum.any?(Bots.grantable_roles(manager), &(&1.id == insider.id))
    end
  end

  defp private_channel_insider_role do
    Bootstrap.ensure_seed_data!()
    private = channel_fixture(%{name: "Private", slug: unique_slug()})

    channel_permission_overwrite_fixture(private, %{
      role_id: Chat.default_role().id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    insider =
      role_fixture(%{
        name: "Insider #{System.unique_integer([:positive])}",
        permissions: 0,
        position: 10
      })

    channel_permission_overwrite_fixture(private, %{
      role_id: insider.id,
      allow_permissions: PermissionBits.combine([:view_channel])
    })

    {private, insider}
  end

  defp member_with(permissions, opts \\ []) do
    role =
      role_fixture(%{
        permissions: PermissionBits.combine(permissions),
        position: Keyword.get(opts, :position, 1)
      })

    member = user_fixture()
    member_role_fixture(member, role)
    member
  end

  defp bot_attrs(attrs \\ %{}) do
    id = System.unique_integer([:positive])

    Map.merge(
      %{
        "display_name" => "Bot #{id}",
        "username" => "bot_#{id}",
        "email" => "bot_#{id}@example.com"
      },
      attrs
    )
  end

  test "get_bot_scope_by_token refuses a valid token whose bot is deactivated" do
    actor = owner_fixture(%{email: "bot-deact-owner@example.com", username: "bot_deact_owner"})
    bot_user = bot_fixture(actor)
    {:ok, %{token: token}} = Bots.create_bot_token(bot_user, %{"label" => "deact"}, actor)
    assert {:ok, _scope} = Bots.get_bot_scope_by_token(token)

    Repo.update_all(from(m in Membership, where: m.user_id == ^bot_user.id),
      set: [deactivated_at: DateTime.utc_now()]
    )

    assert {:error, :unauthorized} = Bots.get_bot_scope_by_token(token)
  end

  defp bot_scope_for(bot_user, actor) do
    {:ok, %{token: token}} = Bots.create_bot_token(bot_user, %{"label" => "test"}, actor)
    {:ok, scope} = Bots.get_bot_scope_by_token(token)
    scope
  end
end
