defmodule Rfchat.ChatTest do
  use Rfchat.DataCase, async: false

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.MessageRoleMention
  alias Rfchat.Chat.MessageUserMention
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.User
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

      channels =
        Chat.list_channels(scope_for(owner_fixture()))
        |> Enum.filter(&(&1.id in [earlier.id, later.id]))

      assert Enum.map(channels, & &1.id) == [earlier.id, later.id]
    end

    test "ensure_channel_memberships_for_user/2 initializes read state and unread_counts_for_user/2 tracks new messages" do
      sender = owner_fixture(%{email: "sender@example.com", username: "sender_user"})
      user = user_fixture(%{email: "reads@example.com", username: "reads_user"})
      engineering = channel_fixture(%{name: "Engineering", slug: unique_slug()})
      channels = [engineering]

      assert :ok = Chat.ensure_channel_memberships(scope_for(user), channels)

      membership =
        Repo.get_by!(Rfchat.Chat.ChannelMembership, user_id: user.id, channel_id: engineering.id)

      refute membership.last_read_message_id

      counts_before = Chat.unread_counts_for_user(user, channels)
      assert counts_before[engineering.id] == 0

      {:ok, message} =
        Chat.create_message(scope_for(sender), engineering.id, %{body: "fresh update"})

      counts_after = Chat.unread_counts_for_user(user, channels)
      assert counts_after[engineering.id] == 1

      Chat.mark_channel_read(user, engineering, message)

      assert Chat.unread_counts_for_user(user, channels)[engineering.id] == 0
    end

    test "a channel manager cannot see or change a channel hidden by its overwrite" do
      %{default_role: default_role} = Bootstrap.ensure_seed_data!()
      manager = channel_manager_fixture()
      visible = channel_fixture(%{name: "Visible", slug: unique_slug(), position: 1})
      hidden = channel_fixture(%{name: "Hidden", slug: unique_slug(), position: 2})
      scope = scope_for(manager)

      channel_permission_overwrite_fixture(hidden, %{
        role_id: default_role.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      tree_channel_ids =
        scope
        |> Chat.list_channel_tree()
        |> Enum.flat_map(& &1.channels)
        |> Enum.map(& &1.id)

      assert visible.id in tree_channel_ids
      refute hidden.id in tree_channel_ids
      assert Chat.get_channel(scope, hidden.id) == Chat.get_channel(scope, Ecto.UUID.generate())
      assert {:error, :not_found} = Chat.update_channel(scope, hidden.id, %{name: "changed"})
      assert {:error, :not_found} = Chat.delete_channel(scope, hidden.id)
      assert {:error, :not_found} = Chat.move_channel(scope, hidden.id, :up)
    end

    test "moving a visible channel skips a hidden sibling and leaves its position intact" do
      %{default_role: default_role} = Bootstrap.ensure_seed_data!()
      manager = channel_manager_fixture()
      category = channel_fixture(%{name: "Move group", slug: unique_slug(), kind: :category})

      first =
        channel_fixture(%{
          name: "First",
          slug: unique_slug(),
          position: 1,
          parent_channel_id: category.id
        })

      hidden =
        channel_fixture(%{
          name: "Hidden",
          slug: unique_slug(),
          position: 2,
          parent_channel_id: category.id
        })

      last =
        channel_fixture(%{
          name: "Last",
          slug: unique_slug(),
          position: 3,
          parent_channel_id: category.id
        })

      scope = scope_for(manager)

      channel_permission_overwrite_fixture(hidden, %{
        role_id: default_role.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      # The guild broadcast skips the process that made the change, so another process listens.
      test_pid = self()

      spawn_link(fn ->
        Rfchat.Chat.Topics.subscribe_guild()
        send(test_pid, :subscribed)

        receive do
          event -> send(test_pid, {:guild_event, event})
        end
      end)

      assert_receive :subscribed
      assert {:ok, %Rfchat.Chat.Channel{position: 3}} = Chat.move_channel(scope, first.id, :down)
      assert_receive {:guild_event, :channels_reordered}
      assert Repo.get!(Rfchat.Chat.Channel, first.id).position == 3
      assert Repo.get!(Rfchat.Chat.Channel, hidden.id).position == 2
      assert Repo.get!(Rfchat.Chat.Channel, last.id).position == 1
    end

    test "moving at either end is a no-op and a visible channel without permission is forbidden" do
      Bootstrap.ensure_seed_data!()
      category = channel_fixture(%{kind: :category})
      first = channel_fixture(%{position: 1, parent_channel_id: category.id})
      last = channel_fixture(%{position: 2, parent_channel_id: category.id})
      manager = scope_for(channel_manager_fixture())
      assert {:ok, unchanged} = Chat.move_channel(manager, first.id, :up)
      assert unchanged.id == first.id
      assert {:ok, unchanged} = Chat.move_channel(manager, last.id, :down)
      assert unchanged.id == last.id
      assert {:error, :not_found} = Chat.move_channel(manager, "invalid-id", :up)
      assert {:error, :not_found} = Chat.update_channel(manager, "invalid-id", %{name: "bad"})
      assert {:error, :not_found} = Chat.delete_channel(manager, "invalid-id")
      assert {:error, :forbidden} = Chat.move_channel(scope_for(user_fixture()), first.id, :up)
    end

    test "channel parents must be visible categories for create and reparent" do
      %{default_role: default_role} = Bootstrap.ensure_seed_data!()
      manager = channel_manager_fixture()
      scope = scope_for(manager)
      hidden = channel_fixture(%{kind: :category})
      child = channel_fixture()

      channel_permission_overwrite_fixture(hidden, %{
        role_id: default_role.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:error, create_error} =
               Chat.create_channel(scope, %{
                 name: "Hidden child",
                 slug: unique_slug(),
                 parent_channel_id: hidden.id
               })

      assert {:error, update_error} =
               Chat.update_channel(scope, child.id, %{parent_channel_id: hidden.id})

      assert errors_on(create_error).parent_channel_id ==
               errors_on(update_error).parent_channel_id
    end

    test "deleting a category keeps hidden child channels at the root" do
      %{default_role: default_role} = Bootstrap.ensure_seed_data!()
      manager = channel_manager_fixture()
      category = channel_fixture(%{kind: :category})
      hidden_child = channel_fixture(%{parent_channel_id: category.id})

      channel_permission_overwrite_fixture(hidden_child, %{
        role_id: default_role.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:ok, _} = Chat.delete_channel(scope_for(manager), category.id)
      assert Repo.get!(Rfchat.Chat.Channel, hidden_child.id).parent_channel_id == nil
    end

    test "channel creation requires manage_channels" do
      Bootstrap.ensure_seed_data!()
      user = user_fixture()

      assert {:error, :forbidden} =
               Chat.create_channel(scope_for(user), %{name: "No", slug: unique_slug()})
    end

    test "unread_mentions_for_user/2 counts unread direct mentions" do
      sender = owner_fixture(%{email: "mention-sender@example.com", username: "mention_sender"})
      user = user_fixture(%{email: "mention-target@example.com", username: "mention_target"})
      engineering = channel_fixture(%{name: "Engineering", slug: unique_slug()})
      channels = [engineering]

      assert :ok = Chat.ensure_channel_memberships(scope_for(user), channels)

      assert {:ok, first_message} =
               Chat.create_message(scope_for(sender), engineering.id, %{
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
        owner_fixture(%{
          email: "role-mention-sender@example.com",
          username: "role_mention_sender"
        })

      user =
        user_fixture(%{email: "role-mention-target@example.com", username: "role_mention_target"})

      role = role_fixture(%{name: "@ops", mentionable: true})
      _member_role = member_role_fixture(user, role)
      engineering = channel_fixture(%{name: "Engineering", slug: unique_slug()})
      channels = [engineering]

      assert :ok = Chat.ensure_channel_memberships(scope_for(user), channels)

      assert {:ok, _message} =
               Chat.create_message(scope_for(sender), engineering.id, %{
                 body: "ping @ops",
                 metadata: %{
                   "entities" => [
                     %{"type" => "mention", "id" => role.id, "label" => "ops"}
                   ]
                 }
               })

      assert Chat.unread_mentions_for_user(user, channels)[engineering.id] == 1
    end

    test "a created message carries the mention rows receivers check" do
      channel = channel_fixture()

      author =
        owner_fixture(%{
          email: "mention-query-author@example.com",
          username: "mention_query_author"
        })

      user =
        user_fixture(%{email: "mention-query-user@example.com", username: "mention_query_user"})

      role = role_fixture(%{name: "@qa", mentionable: true})
      _member_role = member_role_fixture(user, role)

      {:ok, direct_message} =
        Chat.create_message(scope_for(author), channel.id, %{
          body: "hello @mention_query_user",
          metadata: %{
            "entities" => [
              %{"type" => "mention", "id" => user.id, "label" => user.username}
            ]
          }
        })

      {:ok, role_message} =
        Chat.create_message(scope_for(author), channel.id, %{
          body: "hello @qa",
          metadata: %{
            "entities" => [
              %{"type" => "mention", "id" => role.id, "label" => "qa"}
            ]
          }
        })

      [author, user] = Repo.preload([author, user], :member_roles, force: true)

      refute Chat.message_mentions_user?(direct_message, author)
      assert Chat.message_mentions_user?(direct_message, user)
      assert Chat.message_mentions_user?(role_message, user)
    end

    test "metadata cannot mention a user who is absent from the body" do
      channel = channel_fixture()
      author = owner_fixture()
      user = user_fixture(%{username: "metadata_only_target"})

      assert {:ok, message} =
               Chat.create_message(scope_for(author), channel.id, %{
                 body: "plain text",
                 metadata: %{
                   "entities" => [%{"type" => "mention", "id" => user.id}]
                 }
               })

      refute Repo.get_by(MessageUserMention,
               message_id: message.id,
               mentioned_user_id: user.id
             )

      refute Chat.message_mentions_user?(message, Repo.preload(user, :member_roles))
    end

    test "@here and @everyone use the protected default role" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture()
      _owner = owner_fixture()
      author = user_fixture()
      receiver = user_fixture()

      for token <- ["@here", "@everyone"] do
        assert {:error, changeset} =
                 Chat.create_message(scope_for(author), channel.id, %{body: token})

        assert "You do not have permission to mention that role." in errors_on(changeset).body
      end

      allowed_author = owner_fixture()

      for token <- ["@here", "@everyone"] do
        assert {:ok, message} =
                 Chat.create_message(scope_for(allowed_author), channel.id, %{body: token})

        assert Chat.message_mentions_user?(message, Repo.preload(receiver, :member_roles))

        assert Repo.get_by(MessageRoleMention,
                 message_id: message.id,
                 mentioned_role_id: Chat.default_role().id
               )
      end

      assert Chat.unread_mentions_for_user(receiver, [channel])[channel.id] == 2
    end

    test "@here follows the default role, not the name @everyone" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture()
      owner = owner_fixture()
      receiver = user_fixture()

      Chat.default_role() |> Ecto.Changeset.change(name: "Members") |> Repo.update!()
      impostor = role_fixture(%{name: "@everyone", mentionable: true})

      assert {:ok, message} = Chat.create_message(scope_for(owner), channel.id, %{body: "@here"})
      assert [%{mentioned_role_id: role_id}] = message.role_mentions
      assert role_id == Chat.default_role().id
      refute role_id == impostor.id
      assert Chat.message_mentions_user?(message, Repo.preload(receiver, :member_roles))
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
      author = owner_fixture()

      first = message_fixture(channel, author, %{body: "first"})
      second = message_fixture(channel, author, %{body: "second"})

      first_timestamp = ~U[2026-04-02 00:00:00.000001Z]
      second_timestamp = ~U[2026-04-02 00:00:01.000001Z]

      from(message in Message, where: message.id == ^first.id)
      |> Repo.update_all(set: [inserted_at: first_timestamp])

      from(message in Message, where: message.id == ^second.id)
      |> Repo.update_all(set: [inserted_at: second_timestamp])

      assert {:ok, messages} = Chat.list_messages(scope_for(author), channel.id)

      assert Enum.map(messages, & &1.body) == ["first", "second"]
      assert Enum.all?(messages, &match?(%Message{author: %{id: _}}, &1))
    end

    test "create_message/3 trims and validates body" do
      channel = channel_fixture()
      author = owner_fixture()

      assert {:ok, message} =
               Chat.create_message(scope_for(author), channel.id, %{body: "  hey there  "})

      assert message.body == "hey there"

      assert {:error, changeset} =
               Chat.create_message(scope_for(author), channel.id, %{body: "   "})

      assert "can't be blank" in errors_on(changeset).body
    end

    test "create_message/3 and update_message/3 ignore fields only the server sets" do
      channel = channel_fixture()
      author = owner_fixture()
      past = "2020-01-01T00:00:00Z"

      server_fields = %{
        "kind" => "system",
        "nonce" => "forged",
        "pinned_at" => past,
        "edited_at" => past,
        "deleted_at" => past,
        "metadata" => %{"deleted" => true, "document" => %{"big" => "doc"}, "entities" => []}
      }

      assert {:ok, message} =
               Chat.create_message(
                 scope_for(author),
                 channel.id,
                 Map.put(server_fields, "body", "hello")
               )

      assert %{kind: :default, nonce: nil, pinned_at: nil, edited_at: nil, deleted_at: nil} =
               message

      assert message.metadata == %{"entities" => []}
      refute Message.deleted?(message)

      assert {:ok, edited} =
               Chat.update_message(
                 scope_for(author),
                 message.id,
                 Map.put(server_fields, "body", "edited")
               )

      assert %{kind: :default, pinned_at: nil, deleted_at: nil} = edited
      assert DateTime.compare(edited.edited_at, ~U[2021-01-01 00:00:00Z]) == :gt
    end

    test "create_message/3 rejects cross-channel reply targets" do
      channel = channel_fixture(%{slug: unique_slug()})
      other_channel = channel_fixture(%{slug: unique_slug()})
      author = owner_fixture()
      other_message = message_fixture(other_channel, author, %{body: "elsewhere"})

      assert {:error, changeset} =
               Chat.create_message(scope_for(author), channel.id, %{
                 body: "bad reply",
                 reply_to_id: other_message.id
               })

      assert "must reference a message in the same conversation" in errors_on(changeset).reply_to_id
    end

    test "create_public_thread/4 creates a thread channel linked to a starter message" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture(%{slug: unique_slug()})
      author = user_fixture()
      starter = message_fixture(channel, author, %{body: "Discuss roadmap here"})

      assert {:ok, thread} = Chat.create_public_thread(scope_for(author), starter.id)
      assert thread.parent_channel_id == channel.id
      assert thread.starter_message_id == starter.id
      assert thread.kind == :thread_public
      assert Chat.get_thread_for_starter_message(scope_for(author), starter.id).id == thread.id
    end

    test "create_public_thread/4 takes only the name from its attrs" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture()
      other_channel = channel_fixture()
      author = user_fixture()
      other_user = user_fixture()
      starter = message_fixture(channel, author, %{body: "Discuss roadmap here"})
      elsewhere = message_fixture(other_channel, author, %{body: "somewhere else"})

      assert {:ok, thread} =
               Chat.create_public_thread(scope_for(author), starter.id, %{
                 "name" => "Roadmap",
                 "kind" => "text",
                 "parent_channel_id" => other_channel.id,
                 "starter_message_id" => elsewhere.id,
                 "created_by_id" => other_user.id,
                 "locked_at" => "2020-01-01T00:00:00Z"
               })

      assert %{
               name: "Roadmap",
               kind: :thread_public,
               locked_at: nil
             } = thread

      assert {thread.parent_channel_id, thread.starter_message_id, thread.created_by_id} ==
               {channel.id, starter.id, author.id}
    end

    test "channel management refuses threads and parents that are not categories" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture()
      author = user_fixture()
      starter = message_fixture(channel, author, %{body: "thread starter"})
      {:ok, thread} = Chat.create_public_thread(scope_for(author), starter.id)

      assert {:error, changeset} =
               Chat.update_channel(scope_for(owner_fixture()), thread.id, %{
                 "kind" => "text",
                 "parent_channel_id" => nil
               })

      assert errors_on(changeset).kind
      assert {:error, :thread} = Chat.delete_channel(scope_for(owner_fixture()), thread.id)

      assert {:error, changeset} =
               Chat.create_channel(scope_for(owner_fixture()), %{
                 name: "Under text",
                 slug: unique_slug(),
                 parent_channel_id: channel.id
               })

      assert "must be a category" in errors_on(changeset).parent_channel_id

      assert {:error, changeset} =
               Chat.create_channel(scope_for(owner_fixture()), %{
                 name: "Fake thread",
                 slug: unique_slug(),
                 kind: "thread_public"
               })

      assert "is invalid" in errors_on(changeset).kind
    end

    test "thread summaries and scoped message reads return thread conversations" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture(%{slug: unique_slug()})
      author = user_fixture()
      starter = message_fixture(channel, author, %{body: "Thread topic"})
      thread = thread_fixture(channel, starter, author)
      _reply = message_fixture(thread, author, %{body: "thread reply"})

      assert Chat.get_thread(scope_for(author), thread.id).id == thread.id

      assert {:ok, [%Message{body: "thread reply"}]} =
               Chat.list_messages(scope_for(author), thread.id)

      summary = Chat.thread_summaries_for_channel(scope_for(author), channel.id)[starter.id]

      assert summary.thread.id == thread.id
      assert summary.reply_count == 1
    end

    test "create_public_thread/4 is allowed for members by default" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture(%{slug: unique_slug()})
      author = user_fixture()
      _starter = message_fixture(channel, author, %{body: "restricted thread"})

      assert Chat.can_create_public_threads?(channel, author)
    end

    test "thread reads hide hidden threads and thread creation honors permission and timeout" do
      %{default_role: default_role} = Bootstrap.ensure_seed_data!()
      author = user_fixture()
      channel = channel_fixture(%{slug: unique_slug()})
      starter = message_fixture(channel, author, %{body: "thread access"})
      thread = thread_fixture(channel, starter, author)

      channel_permission_overwrite_fixture(channel, %{
        role_id: default_role.id,
        deny_permissions: PermissionBits.combine([:view_channel, :create_public_threads])
      })

      assert Chat.get_thread(scope_for(author), thread.id) == nil
      assert Chat.get_thread(scope_for(author), Ecto.UUID.generate()) == nil
      assert Chat.get_thread_for_starter_message(scope_for(author), starter.id) == nil
      assert Chat.thread_summaries_for_channel(scope_for(author), channel.id) == %{}
      assert {:error, :not_found} = Chat.create_public_thread(scope_for(author), starter.id)

      other_channel = channel_fixture(%{slug: unique_slug()})
      other_starter = message_fixture(other_channel, author, %{body: "permission"})

      channel_permission_overwrite_fixture(other_channel, %{
        role_id: default_role.id,
        deny_permissions: PermissionBits.combine([:create_public_threads])
      })

      assert {:error, :forbidden} =
               Chat.create_public_thread(scope_for(author), other_starter.id)

      timeout_channel = channel_fixture(%{slug: unique_slug()})
      timeout_starter = message_fixture(timeout_channel, author, %{body: "timeout"})
      owner = owner_fixture()
      assert {:ok, _timed_out, _case} = Chat.timeout_member(owner, author, 10)

      assert {:error, :forbidden} =
               Chat.create_public_thread(scope_for(author), timeout_starter.id)
    end

    test "thread creation does not return an existing hidden thread" do
      %{default_role: default_role} = Bootstrap.ensure_seed_data!()
      author = user_fixture()
      channel = channel_fixture()
      starter = message_fixture(channel, author, %{body: "hidden thread"})
      thread = thread_fixture(channel, starter, author)

      channel_permission_overwrite_fixture(thread, %{
        role_id: default_role.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:error, :not_found} = Chat.create_public_thread(scope_for(author), starter.id)
    end

    test "create_message/3 rejects invalid metadata json" do
      channel = channel_fixture()
      author = user_fixture()

      assert {:error, changeset} =
               Chat.create_message(scope_for(author), channel.id, %{body: "hello", metadata: "{"})

      assert "must be valid JSON" in errors_on(changeset).metadata
    end

    test "create_message/3 persists mention join rows from metadata and body" do
      channel = channel_fixture()
      author = owner_fixture()
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
               Chat.create_message(scope_for(author), channel.id, %{
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
      author = owner_fixture()

      first_user =
        user_fixture(%{email: "first-mentioned@example.com", username: "first_mentioned"})

      second_user =
        user_fixture(%{email: "second-mentioned@example.com", username: "second_mentioned"})

      assert {:ok, message} =
               Chat.create_message(scope_for(author), channel.id, %{
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
               Chat.update_message(scope_for(author), message.id, %{
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

    test "update_message/3 refuses an author who is timed out" do
      Bootstrap.ensure_seed_data!()
      owner = owner_fixture()
      channel = channel_fixture()
      author = user_fixture()
      message = message_fixture(channel, author, %{body: "before"})

      assert {:ok, _timed_out, _case} = Chat.timeout_member(owner, author, 10)

      assert {:error, :forbidden} =
               Chat.update_message(scope_for(author), message.id, %{body: "after"})

      assert Repo.get!(Message, message.id).body == "before"
    end

    test "update_message/3 refuses an author who cannot view the channel" do
      Bootstrap.ensure_seed_data!()
      _owner = owner_fixture()
      channel = channel_fixture()
      author = user_fixture()
      message = message_fixture(channel, author, %{body: "before"})

      channel_permission_overwrite_fixture(channel, %{
        role_id: Chat.default_role().id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:error, :not_found} =
               Chat.update_message(scope_for(author), message.id, %{body: "after"})

      assert Repo.get!(Message, message.id).body == "before"
    end

    test "update_message/3 uses current overwrites when given a message loaded before a deny" do
      Bootstrap.ensure_seed_data!()
      _owner = owner_fixture()
      channel = channel_fixture()
      author = user_fixture()
      message = message_fixture(channel, author, %{body: "before"})

      assert {:ok, edited} =
               Chat.update_message(scope_for(author), message.id, %{body: "first edit"})

      channel_permission_overwrite_fixture(channel, %{
        role_id: Chat.default_role().id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:error, :not_found} =
               Chat.update_message(scope_for(author), edited.id, %{body: "second edit"})

      assert Repo.get!(Message, message.id).body == "first edit"
    end

    test "update_message/3 refuses a thread reply when the parent channel is hidden" do
      Bootstrap.ensure_seed_data!()
      _owner = owner_fixture()
      channel = channel_fixture()
      author = user_fixture()
      starter = message_fixture(channel, author, %{body: "Thread topic"})
      thread = thread_fixture(channel, starter, author)
      reply = message_fixture(thread, author, %{body: "before"})

      channel_permission_overwrite_fixture(channel, %{
        role_id: Chat.default_role().id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:error, :not_found} =
               Chat.update_message(scope_for(author), reply.id, %{body: "after"})

      assert Repo.get!(Message, reply.id).body == "before"
    end

    test "create_message/3 rejects locked role mentions without mention_everyone" do
      Bootstrap.ensure_seed_data!()
      channel = channel_fixture()
      _owner = owner_fixture(%{email: "mention-owner@example.com", username: "mention_owner"})
      author = user_fixture(%{email: "mention-member@example.com", username: "mention_member"})
      locked_role = role_fixture(%{name: "@staff", mentionable: false})

      assert {:error, changeset} =
               Chat.create_message(scope_for(author), channel.id, %{
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

      assert {:error, :forbidden} = Chat.toggle_reaction(scope_for(user), message.id, "👍")
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
               Chat.toggle_reaction(scope_for(user), message.id, %{"emoji_id" => emoji.id})

      assert Enum.any?(updated_message.reactions, &(&1.emoji_id == emoji.id))

      assert {:ok, updated_message} =
               Chat.toggle_reaction(scope_for(user), message.id, %{"emoji_id" => emoji.id})

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

      assert {:ok, deleted_message} = Chat.delete_message(scope_for(moderator), message.id)
      assert deleted_message.body == "[message deleted]"
    end
  end

  describe "moderation" do
    setup do
      Bootstrap.ensure_seed_data!()
      _owner = owner_fixture()
      moderator = user_fixture()

      mod_role =
        role_fixture(%{permissions: PermissionBits.combine([:ban_members]), position: 50})

      member_role_fixture(moderator, mod_role)
      %{moderator: moderator}
    end

    test "ban_member/3 bans a member ranked below the moderator", %{moderator: moderator} do
      member = user_fixture()
      member_role_fixture(member, role_fixture(%{position: 10}))

      assert {:ok, banned, _case} = Chat.ban_member(moderator, member)
      assert banned.membership.deactivated_at
    end

    test "ban_member/3 refuses a member ranked at or above the moderator", %{moderator: moderator} do
      peer = user_fixture()
      member_role_fixture(peer, role_fixture(%{position: 50}))

      admin = user_fixture()

      member_role_fixture(
        admin,
        role_fixture(%{permissions: PermissionBits.combine([:administrator]), position: 60})
      )

      assert {:error, :forbidden} = Chat.ban_member(moderator, peer)
      assert {:error, :forbidden} = Chat.ban_member(moderator, admin)
    end
  end

  describe "seed bootstrap" do
    test "ensure_seed_data!/0 creates default channels, role, and welcome message idempotently" do
      first = Bootstrap.ensure_seed_data!()
      assert %{bot: true, system: true} = Repo.get!(User, first.system_user.id)
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

      reader = user_fixture()

      assert Chat.message_count(
               scope_for(reader),
               Enum.find(first.channels, &(&1.slug == "general")).id
             ) == 1
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

      visible_slugs = Chat.list_channels(scope_for(user)) |> Enum.map(& &1.slug)

      assert general.slug in visible_slugs
      refute hidden_channel.slug in visible_slugs
      refute Chat.can_view_channel?(hidden_channel, user)
      refute Chat.can_send_messages?(hidden_channel, user)
    end
  end
end
