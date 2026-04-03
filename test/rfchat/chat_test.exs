defmodule Rfchat.ChatTest do
  use Rfchat.DataCase, async: false

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.MessageRoleMention
  alias Rfchat.Chat.MessageUserMention
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.UserNotificationSetting
  alias Rfchat.Repo

  import Rfchat.ChatFixtures

  setup do
    Rfchat.Accounts.LoginRateLimiter.reset!()
    :ok
  end

  describe "channels" do
    test "list_channels/0 returns channels ordered by position" do
      later = channel_fixture(%{name: "Later", slug: unique_slug(), position: 2})
      earlier = channel_fixture(%{name: "Earlier", slug: unique_slug(), position: 1})

      assert Enum.map(Chat.list_channels(), & &1.id) == [earlier.id, later.id]
    end

    test "ensure_channel_memberships_for_user/2 initializes read state and unread_counts_for_user/2 tracks new messages" do
      sender = user_fixture(%{email: "sender@example.com", username: "sender_user"})
      user = user_fixture(%{email: "reads@example.com", username: "reads_user"})
      engineering = channel_fixture(%{name: "Engineering", slug: unique_slug()})
      channels = [engineering]

      assert :ok = Chat.ensure_channel_memberships_for_user(user, channels)

      membership =
        Repo.get_by!(Rfchat.Chat.ChannelMembership, user_id: user.id, channel_id: engineering.id)

      refute membership.last_read_message_id

      counts_before = Chat.unread_counts_for_user(user, channels)
      assert counts_before[engineering.id] == 0

      {:ok, message} = Chat.create_message(engineering, sender, %{body: "fresh update"})

      counts_after = Chat.unread_counts_for_user(user, channels)
      assert counts_after[engineering.id] == 1

      Chat.mark_channel_read(user, engineering, message)

      assert Chat.unread_counts_for_user(user, channels)[engineering.id] == 0
    end

    test "unread_mentions_for_user/2 counts unread direct mentions" do
      sender = user_fixture(%{email: "mention-sender@example.com", username: "mention_sender"})
      user = user_fixture(%{email: "mention-target@example.com", username: "mention_target"})
      engineering = channel_fixture(%{name: "Engineering", slug: unique_slug()})
      channels = [engineering]

      assert :ok = Chat.ensure_channel_memberships_for_user(user, channels)

      assert {:ok, first_message} =
               Chat.create_message(engineering, sender, %{
                 body: "hello @mention_target",
                 metadata: %{
                   "entities" => [
                     %{"type" => "mention", "id" => user.id, "label" => user.username}
                   ]
                 }
               })

      assert Chat.unread_mentions_for_user(user, channels)[engineering.id] == 1

      Chat.mark_channel_read(user, engineering, first_message)

      assert Chat.unread_mentions_for_user(user, channels)[engineering.id] == 0
    end

    test "unread_mentions_for_user/2 counts unread role mentions for member roles" do
      sender =
        user_fixture(%{email: "role-mention-sender@example.com", username: "role_mention_sender"})

      user =
        user_fixture(%{email: "role-mention-target@example.com", username: "role_mention_target"})

      role = role_fixture(%{name: "@ops", mentionable: true})
      _member_role = member_role_fixture(user, role)
      engineering = channel_fixture(%{name: "Engineering", slug: unique_slug()})
      channels = [engineering]

      assert :ok = Chat.ensure_channel_memberships_for_user(user, channels)

      assert {:ok, _message} =
               Chat.create_message(engineering, sender, %{
                 body: "ping @ops",
                 metadata: %{
                   "entities" => [
                     %{"type" => "mention", "id" => role.id, "label" => "ops"}
                   ]
                 }
               })

      assert Chat.unread_mentions_for_user(user, channels)[engineering.id] == 1
    end

    test "message_mentions_user?/2 returns true for direct and role mentions" do
      channel = channel_fixture()

      author =
        user_fixture(%{
          email: "mention-query-author@example.com",
          username: "mention_query_author"
        })

      user =
        user_fixture(%{email: "mention-query-user@example.com", username: "mention_query_user"})

      role = role_fixture(%{name: "@qa", mentionable: true})
      _member_role = member_role_fixture(user, role)

      {:ok, direct_message} =
        Chat.create_message(channel, author, %{
          body: "hello @mention_query_user",
          metadata: %{
            "entities" => [
              %{"type" => "mention", "id" => user.id, "label" => user.username}
            ]
          }
        })

      {:ok, role_message} =
        Chat.create_message(channel, author, %{
          body: "hello @qa",
          metadata: %{
            "entities" => [
              %{"type" => "mention", "id" => role.id, "label" => "qa"}
            ]
          }
        })

      refute Chat.message_mentions_user?(direct_message.id, author)
      assert Chat.message_mentions_user?(direct_message.id, user)
      assert Chat.message_mentions_user?(role_message.id, user)
    end

    test "mention_notifications_enabled?/2 respects user desktop mention setting" do
      user = user_fixture(%{email: "notify-prefs@example.com", username: "notify_prefs"})
      channel = channel_fixture()

      assert Chat.mention_notifications_enabled?(user, channel)

      assert {:ok, %UserNotificationSetting{} = setting} =
               Chat.update_user_notification_setting(user, %{
                 desktop_enabled: false,
                 notify_on_mentions: true
               })

      refute setting.desktop_enabled
      refute Chat.mention_notifications_enabled?(user, channel)
    end
  end

  describe "messages" do
    test "list_messages/2 returns oldest-to-newest messages with authors preloaded" do
      channel = channel_fixture()
      author = user_fixture()

      first = message_fixture(channel, author, %{body: "first"})
      second = message_fixture(channel, author, %{body: "second"})

      first_timestamp = ~U[2026-04-02 00:00:00.000001Z]
      second_timestamp = ~U[2026-04-02 00:00:01.000001Z]

      from(message in Message, where: message.id == ^first.id)
      |> Repo.update_all(set: [inserted_at: first_timestamp])

      from(message in Message, where: message.id == ^second.id)
      |> Repo.update_all(set: [inserted_at: second_timestamp])

      messages = Chat.list_messages(channel.id)

      assert Enum.map(messages, & &1.body) == ["first", "second"]
      assert Enum.all?(messages, &match?(%Message{author: %{id: _}}, &1))
    end

    test "create_message/3 trims and validates body" do
      channel = channel_fixture()
      author = user_fixture()

      assert {:ok, message} = Chat.create_message(channel, author, %{body: "  hey there  "})
      assert message.body == "hey there"

      assert {:error, changeset} = Chat.create_message(channel, author, %{body: "   "})
      assert "can't be blank" in errors_on(changeset).body
    end

    test "create_message/3 rejects invalid metadata json" do
      channel = channel_fixture()
      author = user_fixture()

      assert {:error, changeset} =
               Chat.create_message(channel, author, %{body: "hello", metadata: "{"})

      assert "must be valid JSON" in errors_on(changeset).metadata
    end

    test "create_message/3 persists mention join rows from metadata and body" do
      channel = channel_fixture()
      author = user_fixture()
      mentioned_user = user_fixture(%{email: "mentioned@example.com", username: "mentioned_user"})
      mentioned_role = role_fixture(%{name: "@ops", mentionable: true})

      metadata = %{
        "composer" => "tiptap",
        "entities" => [
          %{"type" => "mention", "id" => mentioned_user.id, "label" => mentioned_user.username},
          %{"type" => "mention", "id" => mentioned_role.id, "label" => "ops"}
        ]
      }

      assert {:ok, message} =
               Chat.create_message(channel, author, %{
                 body: "hello @mentioned_user and @ops",
                 metadata: metadata
               })

      assert Repo.get_by(MessageUserMention,
               message_id: message.id,
               mentioned_user_id: mentioned_user.id
             )

      assert Repo.get_by(MessageRoleMention,
               message_id: message.id,
               mentioned_role_id: mentioned_role.id
             )
    end

    test "update_message/3 refreshes mention join rows" do
      channel = channel_fixture()
      author = user_fixture()

      first_user =
        user_fixture(%{email: "first-mentioned@example.com", username: "first_mentioned"})

      second_user =
        user_fixture(%{email: "second-mentioned@example.com", username: "second_mentioned"})

      assert {:ok, message} =
               Chat.create_message(channel, author, %{
                 body: "hello @first_mentioned",
                 metadata: %{
                   "entities" => [
                     %{"type" => "mention", "id" => first_user.id, "label" => first_user.username}
                   ]
                 }
               })

      assert Repo.get_by(MessageUserMention,
               message_id: message.id,
               mentioned_user_id: first_user.id
             )

      assert {:ok, updated_message} =
               Chat.update_message(message, author, %{
                 body: "hello @second_mentioned",
                 metadata: %{
                   "entities" => [
                     %{
                       "type" => "mention",
                       "id" => second_user.id,
                       "label" => second_user.username
                     }
                   ]
                 }
               })

      refute Repo.get_by(MessageUserMention,
               message_id: updated_message.id,
               mentioned_user_id: first_user.id
             )

      assert Repo.get_by(MessageUserMention,
               message_id: updated_message.id,
               mentioned_user_id: second_user.id
             )
    end

    test "create_message/3 rejects locked role mentions without mention_everyone" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture()
      _owner = user_fixture(%{email: "mention-owner@example.com", username: "mention_owner"})
      author = user_fixture(%{email: "mention-member@example.com", username: "mention_member"})
      locked_role = role_fixture(%{name: "@staff", mentionable: false})

      assert {:error, changeset} =
               Chat.create_message(channel, author, %{
                 body: "hello @staff",
                 metadata: %{
                   "entities" => [
                     %{"type" => "mention", "id" => locked_role.id, "label" => "staff"}
                   ]
                 }
               })

      assert "You do not have permission to mention that role." in errors_on(changeset).body
    end

    test "toggle_reaction/3 rejects users without add_reactions permission" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture()
      author = user_fixture(%{email: "react-author@example.com", username: "react_author"})
      user = user_fixture(%{email: "react-target@example.com", username: "react_target"})
      message = message_fixture(channel, author)

      channel_permission_overwrite_fixture(channel, %{
        role_id: Chat.default_role().id,
        deny_permissions: PermissionBits.combine([:add_reactions])
      })

      assert {:error, :forbidden} = Chat.toggle_reaction(message, user, "👍")
      refute Chat.can_add_reactions?(channel, user)
    end

    test "toggle_reaction/3 supports custom emoji reactions" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture()

      author =
        user_fixture(%{email: "emoji-react-author@example.com", username: "emoji_react_author"})

      user = user_fixture(%{email: "emoji-react-user@example.com", username: "emoji_react_user"})
      message = message_fixture(channel, author)
      emoji = emoji_fixture(author, %{name: "blobwave", shortcode: ":blobwave:"})

      assert {:ok, updated_message} =
               Chat.toggle_reaction(message, user, %{"emoji_id" => emoji.id})

      assert Enum.any?(updated_message.reactions, &(&1.emoji_id == emoji.id))

      assert {:ok, updated_message} =
               Chat.toggle_reaction(message, user, %{"emoji_id" => emoji.id})

      refute Enum.any?(updated_message.reactions, &(&1.emoji_id == emoji.id))
    end

    test "list_available_emojis/1 includes listed emoji" do
      Bootstrap.ensure_seed_data!()
      user = user_fixture(%{email: "emoji-list-user@example.com", username: "emoji_list_user"})
      emoji = emoji_fixture(user, %{name: "partyblob", shortcode: ":partyblob:"})

      assert Enum.any?(Chat.list_available_emojis(user), &(&1.id == emoji.id))
    end

    test "delete_message/2 allows moderators with manage_messages" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture()
      author = user_fixture(%{email: "delete-author@example.com", username: "delete_author"})
      moderator = user_fixture(%{email: "moderator@example.com", username: "moderator_user"})

      role =
        role_fixture(%{
          name: "Moderator",
          permissions: PermissionBits.combine([:manage_messages])
        })

      _member_role = member_role_fixture(moderator, role)
      moderator = Repo.preload(moderator, [:membership, member_roles: :role], force: true)
      message = message_fixture(channel, author, %{body: "please moderate"})

      assert {:ok, deleted_message} = Chat.delete_message(message, moderator)
      assert deleted_message.body == "[message deleted]"
    end
  end

  describe "seed bootstrap" do
    test "ensure_seed_data!/0 creates default channels, role, and welcome message idempotently" do
      first = Bootstrap.ensure_seed_data!()
      second = Bootstrap.ensure_seed_data!()

      assert first.system_user.id == second.system_user.id
      assert Enum.map(first.channels, & &1.slug) == ["general", "engineering", "random"]
      assert first.default_role.is_default

      assert first.default_role.permissions ==
               PermissionBits.combine([
                 :view_channel,
                 :send_messages,
                 :create_public_threads,
                 :send_messages_in_threads,
                 :embed_links,
                 :attach_files,
                 :add_reactions
               ])

      assert Chat.message_count(Enum.find(first.channels, &(&1.slug == "general")).id) == 1
    end

    test "default role governs channel visibility and posting" do
      %{channels: [general | _rest]} = Bootstrap.ensure_seed_data!()
      hidden_channel = channel_fixture(%{name: "Staff", slug: unique_slug(), position: 99})

      _owner =
        user_fixture(%{
          email: "owner-perms@example.com",
          username: "owner_perms"
        })

      user =
        user_fixture(%{
          email: "member-perms@example.com",
          username: "member_perms"
        })

      channel_permission_overwrite_fixture(hidden_channel, %{
        role_id: Chat.default_role().id,
        deny_permissions: PermissionBits.combine([:view_channel, :send_messages])
      })

      visible_slugs = user |> Chat.list_channels_for_user() |> Enum.map(& &1.slug)

      assert general.slug in visible_slugs
      refute hidden_channel.slug in visible_slugs
      refute Chat.can_view_channel?(hidden_channel, user)
      refute Chat.can_send_messages?(hidden_channel, user)
    end
  end
end
