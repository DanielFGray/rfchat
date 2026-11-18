defmodule Rfchat.Chat.VisibilityTest do
  use Rfchat.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Rfchat.Accounts.Scope
  alias Rfchat.Bots
  alias Rfchat.Chat
  alias Rfchat.Chat.BotToken
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.Visibility
  alias Rfchat.Repo

  import Rfchat.ChatFixtures

  defp bits(names), do: PermissionBits.combine(names)

  defp overwrite_role(channel, role, attrs),
    do: channel_permission_overwrite_fixture(channel, Map.put(attrs, :role_id, role.id))

  defp overwrite_user(channel, user, attrs),
    do: channel_permission_overwrite_fixture(channel, Map.put(attrs, :user_id, user.id))

  defp can?(user, action, target),
    do: Visibility.can?(%Scope{user_id: user.id}, action, target)

  # The test database may hold no default role; the partial unique index allows only one.
  defp default_role,
    do: Chat.default_role() || role_fixture(%{name: "Everyone", is_default: true, permissions: 0})

  defp set_membership(user, attrs),
    do: Repo.update_all(from(m in Membership, where: m.user_id == ^user.id), set: attrs)

  describe "channel_ids/1 and can?/3 agree" do
    test "the list path returns exactly the channels the by-id path allows" do
      owner = owner_fixture(%{email: "vis-owner@example.com", username: "vis_owner"})
      member = user_fixture(%{email: "vis-member@example.com", username: "vis_member"})

      viewer = role_fixture(%{name: "Viewer", permissions: bits([:view_channel])})
      _viewer_role = member_role_fixture(member, viewer)

      open = channel_fixture(%{name: "Open", slug: unique_slug()})
      hidden = channel_fixture(%{name: "Hidden", slug: unique_slug()})
      allowed_for_member = channel_fixture(%{name: "Allowed", slug: unique_slug()})

      # The role's view bit is denied on `hidden`, and the member is granted it back on
      # `allowed_for_member` by a user overwrite. Both paths must agree on each channel.
      overwrite_role(hidden, viewer, %{deny_permissions: bits([:view_channel])})
      overwrite_role(allowed_for_member, viewer, %{deny_permissions: bits([:view_channel])})
      overwrite_user(allowed_for_member, member, %{allow_permissions: bits([:view_channel])})

      starter = message_fixture(open, owner, %{body: "parent of a thread"})
      thread_in_open = thread_fixture(open, starter, owner)

      hidden_starter = message_fixture(hidden, owner, %{body: "under a hidden parent"})
      thread_in_hidden = thread_fixture(hidden, hidden_starter, owner)

      scope = %Scope{user_id: member.id}
      listed = Visibility.channel_ids(scope)

      by_id =
        Repo.all(Channel)
        |> Enum.filter(&Visibility.can?(scope, :view_channel, &1))
        |> MapSet.new(& &1.id)

      assert MapSet.new(listed) == by_id
      assert listed == Enum.map(Visibility.visible_channels(scope), & &1.id)
      assert open.id in listed
      assert allowed_for_member.id in listed
      assert thread_in_open.id in listed
      refute hidden.id in listed
      refute thread_in_hidden.id in listed
    end
  end

  describe "overwrite precedence" do
    setup do
      member = user_fixture(%{email: "prec-member@example.com", username: "prec_member"})
      role = role_fixture(%{name: "Prec viewer", permissions: bits([:view_channel])})
      _member_role = member_role_fixture(member, role)

      %{member: member, role: role, default_role: default_role()}
    end

    test "the default role's deny applies after the base, and the role's allow comes after it",
         %{member: member, role: role, default_role: default_role} do
      channel = channel_fixture(%{name: "Default deny", slug: unique_slug()})
      assert can?(member, :view_channel, channel)

      overwrite_role(channel, default_role, %{deny_permissions: bits([:view_channel])})
      refute can?(member, :view_channel, channel)

      overwrite_role(channel, role, %{allow_permissions: bits([:view_channel])})
      assert can?(member, :view_channel, channel)
    end

    test "a member overwrite denies a view the member's role grants",
         %{member: member} do
      channel = channel_fixture(%{name: "Member deny", slug: unique_slug()})
      assert can?(member, :view_channel, channel)

      overwrite_user(channel, member, %{deny_permissions: bits([:view_channel])})
      refute can?(member, :view_channel, channel)
    end

    test "a member overwrite allows a view a role overwrite denied",
         %{member: member, role: role} do
      channel = channel_fixture(%{name: "Member allow", slug: unique_slug()})
      overwrite_role(channel, role, %{deny_permissions: bits([:view_channel])})
      refute can?(member, :view_channel, channel)

      overwrite_user(channel, member, %{allow_permissions: bits([:view_channel])})
      assert can?(member, :view_channel, channel)
    end

    test "a parent's overwrite decides its thread, and a thread allow cannot reopen a hidden parent",
         %{member: member} do
      owner = owner_fixture(%{email: "prec-parent-owner@example.com", username: "prec_p_owner"})
      parent = channel_fixture(%{name: "Parent", slug: unique_slug()})
      starter = message_fixture(parent, owner, %{body: "start"})
      thread = thread_fixture(parent, starter, owner)
      assert can?(member, :view_channel, thread)

      overwrite_user(parent, member, %{deny_permissions: bits([:view_channel])})
      refute can?(member, :view_channel, parent)
      refute can?(member, :view_channel, thread)

      overwrite_user(thread, member, %{allow_permissions: bits([:view_channel])})
      refute can?(member, :view_channel, thread)

      refute thread.id in Visibility.channel_ids(%Scope{user_id: member.id})
    end
  end

  describe "administrator and owner" do
    test "administrator overrides a channel's view denial" do
      admin = user_fixture(%{email: "prec-admin@example.com", username: "prec_admin"})
      admin_role = role_fixture(%{name: "Admins", permissions: bits([:administrator])})
      _admin_role = member_role_fixture(admin, admin_role)
      channel = channel_fixture(%{name: "Admin denied", slug: unique_slug()})

      overwrite_role(channel, admin_role, %{deny_permissions: bits([:view_channel])})

      assert can?(admin, :view_channel, channel)
    end

    test "the owner overrides a default-role view denial" do
      owner = owner_fixture(%{email: "prec-owner@example.com", username: "prec_owner"})
      channel = channel_fixture(%{name: "Owner denied", slug: unique_slug()})

      overwrite_role(channel, default_role(), %{deny_permissions: bits([:view_channel])})

      assert can?(owner, :view_channel, channel)
    end
  end

  describe "thread rules" do
    setup do
      owner = owner_fixture(%{email: "thr-owner@example.com", username: "thr_owner"})
      member = user_fixture(%{email: "thr-member@example.com", username: "thr_member"})

      role =
        role_fixture(%{
          name: "Thread talker",
          permissions:
            bits([
              :view_channel,
              :send_messages,
              :send_messages_in_threads,
              :add_reactions,
              :create_public_threads
            ])
        })

      _member_role = member_role_fixture(member, role)
      parent = channel_fixture(%{name: "Talk", slug: unique_slug()})
      starter = message_fixture(parent, owner, %{body: "thread starter"})
      thread = thread_fixture(parent, starter, owner)

      %{owner: owner, member: member, role: role, parent: parent, thread: thread}
    end

    test "a thread send needs the parent's send, not only the thread's grant",
         %{member: member, role: role, parent: parent, thread: thread} do
      assert can?(member, :send_messages_in_threads, thread)

      overwrite_role(parent, role, %{deny_permissions: bits([:send_messages])})

      refute can?(member, :send_messages_in_threads, thread)
      assert can?(member, :view_channel, thread)
    end

    test "a timed-out member may view but not send, react, start threads or send in threads",
         %{member: member, parent: parent, thread: thread} do
      own_message = message_fixture(parent, member, %{body: "before the timeout"})

      set_membership(member,
        timeout_until:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      )

      assert can?(member, :view_channel, parent)
      assert can?(member, :view_channel, thread)
      refute can?(member, :send_messages, parent)
      refute can?(member, :add_reactions, parent)
      refute can?(member, :create_public_threads, parent)
      refute can?(member, :send_messages_in_threads, thread)
      refute can?(member, :edit_message, own_message)
    end
  end

  describe "moderation" do
    setup do
      actor = user_fixture(%{email: "mod-actor@example.com", username: "mod_actor"})

      mod_role =
        role_fixture(%{
          name: "Mod",
          position: 1001,
          permissions: bits([:kick_members, :ban_members])
        })

      _actor_role = member_role_fixture(actor, mod_role)

      %{actor: actor, mod_role: mod_role}
    end

    test "a subject with an equal or higher top role is refused", %{
      actor: actor,
      mod_role: mod_role
    } do
      equal = user_fixture(%{email: "mod-equal@example.com", username: "mod_equal"})
      _equal_role = member_role_fixture(equal, mod_role)

      higher_role = role_fixture(%{name: "Higher", position: 1002, permissions: 0})
      higher = user_fixture(%{email: "mod-higher@example.com", username: "mod_higher"})
      _higher_role = member_role_fixture(higher, higher_role)

      refute can?(actor, {:moderate, :kick_members}, equal.id)
      refute can?(actor, {:moderate, :kick_members}, higher.id)
    end

    test "a subject with a lower top role can be moderated", %{actor: actor} do
      lower_role = role_fixture(%{name: "Lower", position: 500, permissions: 0})
      lower = user_fixture(%{email: "mod-lower@example.com", username: "mod_lower"})
      _lower_role = member_role_fixture(lower, lower_role)

      assert can?(actor, {:moderate, :kick_members}, lower.id)
    end

    test "the owner cannot be moderated, even by an administrator" do
      admin = user_fixture(%{email: "mod-admin@example.com", username: "mod_admin"})

      admin_role =
        role_fixture(%{name: "Admins", position: 1003, permissions: bits([:administrator])})

      _admin_role = member_role_fixture(admin, admin_role)
      owner = owner_fixture(%{email: "mod-owner@example.com", username: "mod_owner"})

      refute can?(admin, {:moderate, :ban_members}, owner.id)
    end

    test "the owner may moderate a member with a higher top role" do
      owner = owner_fixture(%{email: "mod-owner-acts@example.com", username: "mod_owner_acts"})
      high_role = role_fixture(%{name: "High", position: 2000, permissions: 0})
      high = user_fixture(%{email: "mod-high@example.com", username: "mod_high"})
      _high_role = member_role_fixture(high, high_role)

      assert can?(owner, {:moderate, :ban_members}, high.id)
    end

    test "a kicked member can still be banned, because the subject's rank is read whatever its state",
         %{actor: actor} do
      subject = user_fixture(%{email: "mod-kicked@example.com", username: "mod_kicked"})

      assert {:ok, _kicked, _case} = Chat.kick_member(scope_for(actor), subject.id)
      assert can?(actor, {:moderate, :ban_members}, subject.id)
      assert {:ok, _banned, _case} = Chat.ban_member(scope_for(actor), subject.id)
    end
  end

  describe "bot tokens" do
    test "an expired token has no member and sees nothing, like a revoked one" do
      actor = owner_fixture(%{email: "exp-bot-owner@example.com", username: "exp_bot_owner"})
      channel = channel_fixture(%{name: "Expiry gate", slug: unique_slug()})
      viewer = role_fixture(%{name: "Expiry viewer", permissions: bits([:view_channel])})
      bot_user = bot_fixture(actor, %{"role_ids" => [viewer.id]})

      {:ok, %{token: token}} = Bots.create_bot_token(bot_user, %{"label" => "expiry"}, actor)
      {:ok, scope} = Bots.get_bot_scope_by_token(token)
      assert Visibility.can?(scope, :view_channel, channel)

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(t in BotToken, where: t.id == ^scope.bot_token_id),
        set: [expires_at: past]
      )

      assert Visibility.member(scope) == nil
      refute Visibility.can?(scope, :view_channel, channel)
      assert Visibility.channel_ids(scope) == []
    end

    test "a revoked bot token has no member, even though the bot user is active" do
      actor = owner_fixture(%{email: "vis-bot-owner@example.com", username: "vis_bot_owner"})
      channel = channel_fixture(%{name: "Bot gate", slug: unique_slug()})

      viewer =
        role_fixture(%{name: "Bot viewer", permissions: bits([:view_channel])})

      bot_user = bot_fixture(actor, %{"role_ids" => [viewer.id]})

      {:ok, %{token: token}} = Bots.create_bot_token(bot_user, %{"label" => "gate"}, actor)
      {:ok, scope} = Bots.get_bot_scope_by_token(token)
      assert Visibility.can?(scope, :view_channel, channel)

      bot_token = Repo.get!(BotToken, scope.bot_token_id)
      {:ok, _revoked} = Bots.revoke_bot_token(bot_token, actor)

      assert Visibility.member(scope) == nil
      refute Visibility.can?(scope, :view_channel, channel)
    end
  end

  describe "membership gates" do
    test "a deactivated member has no member and is denied every channel" do
      owner = owner_fixture(%{email: "vis-deact-owner@example.com", username: "vis_deact_o"})
      member = user_fixture(%{email: "vis-deact@example.com", username: "vis_deact"})
      channel = channel_fixture(%{name: "Gate", slug: unique_slug()})

      set_membership(member, deactivated_at: DateTime.utc_now())

      scope = %Scope{user_id: member.id}
      assert Visibility.member(scope) == nil
      refute Visibility.can?(scope, :view_channel, channel)
      assert Visibility.channel_ids(scope) == []

      # The owner stays a valid actor, so the gate is about this member only.
      assert Visibility.can?(%Scope{user_id: owner.id}, :view_channel, channel)
    end
  end
end
