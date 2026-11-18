defmodule Tavern.Chat.ScopedMessagesTest do
  @moduledoc """
  Message and reaction operations take a scope and an id. A row the scope may not view answers as a
  missing row does, a visible row the scope may not change is forbidden, and every decision is
  made again on each call.
  """
  use Tavern.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Tavern.ChatFixtures

  alias Tavern.Accounts.Scope
  alias Tavern.Chat
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Message
  alias Tavern.Chat.PermissionBits
  alias Tavern.Repo

  setup do
    owner = owner_fixture(%{email: "scoped-owner@example.com", username: "scoped_owner"})
    member = user_fixture(%{email: "scoped-member@example.com", username: "scoped_member"})

    viewer =
      role_fixture(%{
        name: "Scoped viewer",
        permissions: PermissionBits.combine([:view_channel, :send_messages, :add_reactions])
      })

    member_role_fixture(member, viewer)

    open = channel_fixture(%{name: "Open", slug: unique_slug()})
    hidden = channel_fixture(%{name: "Hidden", slug: unique_slug()})

    channel_permission_overwrite_fixture(hidden, %{
      role_id: viewer.id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    %{
      owner: owner,
      member: member,
      viewer: viewer,
      scope: %Scope{user_id: member.id},
      open: open,
      hidden: hidden,
      owner_message: message_fixture(open, owner, %{body: "owner says hi"}),
      hidden_message: message_fixture(hidden, owner, %{body: "secret"})
    }
  end

  defp missing_id, do: Ecto.UUID.generate()

  describe "a hidden row answers as a missing row" do
    test "reads return the same answer for a hidden channel and a missing one", ctx do
      assert {:error, :not_found} = Chat.list_messages(ctx.scope, ctx.hidden.id)
      assert {:error, :not_found} = Chat.list_messages(ctx.scope, missing_id())

      assert nil == Chat.get_message(ctx.scope, ctx.hidden_message.id)
      assert nil == Chat.get_message(ctx.scope, missing_id())

      assert Chat.message_count(ctx.scope, ctx.hidden.id) == 0
      assert Chat.message_count(ctx.scope, missing_id()) == 0

      assert Chat.list_typing_users(ctx.scope, ctx.hidden.id) == []
      assert Chat.list_typing_users(ctx.scope, missing_id()) == []
    end

    test "writes return the same answer for a hidden channel and a missing one", ctx do
      assert {:error, :not_found} =
               Chat.create_message(ctx.scope, ctx.hidden.id, %{"body" => "nope"})

      assert {:error, :not_found} =
               Chat.create_message(ctx.scope, missing_id(), %{"body" => "nope"})

      assert {:error, :not_found} = Chat.announce_typing(ctx.scope, ctx.hidden.id)
      assert {:error, :not_found} = Chat.announce_typing(ctx.scope, missing_id())
    end

    test "a message in a hidden channel cannot be edited, deleted or reacted to", ctx do
      assert {:error, :not_found} =
               Chat.update_message(ctx.scope, ctx.hidden_message.id, %{body: "edited"})

      assert {:error, :not_found} = Chat.delete_message(ctx.scope, ctx.hidden_message.id)
      assert {:error, :not_found} = Chat.toggle_reaction(ctx.scope, ctx.hidden_message.id, "👍")

      assert {:error, :not_found} = Chat.update_message(ctx.scope, missing_id(), %{body: "x"})
      assert {:error, :not_found} = Chat.delete_message(ctx.scope, missing_id())
      assert {:error, :not_found} = Chat.toggle_reaction(ctx.scope, missing_id(), "👍")

      assert Repo.get!(Message, ctx.hidden_message.id).body == "secret"
      assert Repo.get!(Message, ctx.hidden_message.id).deleted_at == nil
    end

    test "a message id that is not a UUID is missing, not an error", ctx do
      assert nil == Chat.get_message(ctx.scope, "not-a-uuid")
      assert {:error, :not_found} = Chat.update_message(ctx.scope, "not-a-uuid", %{body: "x"})
    end
  end

  describe "a visible row the scope may not change is forbidden" do
    test "another author's message can be read but not edited or deleted", ctx do
      assert %Message{} = Chat.get_message(ctx.scope, ctx.owner_message.id)

      assert {:error, :forbidden} =
               Chat.update_message(ctx.scope, ctx.owner_message.id, %{body: "mine now"})

      assert {:error, :forbidden} = Chat.delete_message(ctx.scope, ctx.owner_message.id)
      assert Repo.get!(Message, ctx.owner_message.id).body == "owner says hi"
    end

    test "a member may create, edit their own message, and react in an open channel", ctx do
      assert {:ok, message} =
               Chat.create_message(ctx.scope, ctx.open.id, %{"body" => "hello"})

      assert message.author.id == ctx.member.id
      assert message.channel.id == ctx.open.id

      assert {:ok, edited} = Chat.update_message(ctx.scope, message.id, %{body: "hello again"})
      assert edited.body == "hello again"

      assert {:ok, reacted} = Chat.toggle_reaction(ctx.scope, message.id, "👍")
      assert [%{emoji_unicode: "👍"}] = reacted.reactions
    end
  end

  describe "timeouts" do
    test "a timed-out member cannot create, edit or react, and can still read", ctx do
      {:ok, own} = Chat.create_message(ctx.scope, ctx.open.id, %{"body" => "before timeout"})
      time_out(ctx.member)

      assert {:error, :forbidden} =
               Chat.create_message(ctx.scope, ctx.open.id, %{"body" => "during timeout"})

      assert {:error, :forbidden} = Chat.update_message(ctx.scope, own.id, %{body: "edited"})
      assert {:error, :forbidden} = Chat.toggle_reaction(ctx.scope, ctx.owner_message.id, "👍")

      assert {:ok, [_, _]} = Chat.list_messages(ctx.scope, ctx.open.id)
    end
  end

  describe "decisions are made on each call" do
    test "a member who loses view between two calls is refused on the second", ctx do
      shifting = channel_fixture(%{name: "Shifting", slug: unique_slug()})
      {:ok, _} = Chat.create_message(ctx.scope, shifting.id, %{"body" => "first"})

      assert {:ok, [_]} = Chat.list_messages(ctx.scope, shifting.id)

      channel_permission_overwrite_fixture(shifting, %{
        role_id: ctx.viewer.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      assert {:error, :not_found} = Chat.list_messages(ctx.scope, shifting.id)

      assert {:error, :not_found} =
               Chat.create_message(ctx.scope, shifting.id, %{"body" => "second"})
    end
  end

  describe "reply_to_id" do
    test "a reply must name a message in the same channel", ctx do
      other = message_fixture(channel_fixture(%{name: "Other", slug: unique_slug()}), ctx.owner)

      assert {:error, changeset} =
               Chat.create_message(ctx.scope, ctx.open.id, %{
                 "body" => "reply",
                 "reply_to_id" => other.id
               })

      assert "must reference a message in the same conversation" in errors_on(changeset).reply_to_id
    end

    test "a reply to a hidden message gets the same error as a reply to a missing one", ctx do
      assert {:error, hidden_changeset} =
               Chat.create_message(ctx.scope, ctx.open.id, %{
                 "body" => "reply",
                 "reply_to_id" => ctx.hidden_message.id
               })

      assert {:error, missing_changeset} =
               Chat.create_message(ctx.scope, ctx.open.id, %{
                 "body" => "reply",
                 "reply_to_id" => missing_id()
               })

      assert errors_on(hidden_changeset).reply_to_id == errors_on(missing_changeset).reply_to_id
    end
  end

  describe "a deleted message takes no action" do
    test "a moderator's delete is final: the author's edit and reaction and a second delete are missing",
         ctx do
      {:ok, own} = Chat.create_message(ctx.scope, ctx.open.id, %{"body" => "before delete"})
      moderator = %Scope{user_id: ctx.owner.id}

      assert {:ok, deleted} = Chat.delete_message(moderator, own.id)
      assert deleted.deleted_at

      assert {:error, :not_found} = Chat.update_message(ctx.scope, own.id, %{body: "revived"})
      assert {:error, :not_found} = Chat.toggle_reaction(ctx.scope, own.id, "👍")
      assert {:error, :not_found} = Chat.delete_message(moderator, own.id)

      assert Repo.get!(Message, own.id).body == "[message deleted]"
    end
  end

  describe "reads of several messages" do
    test "get_messages/2 returns the visible messages among the ids, in the order given", ctx do
      {:ok, own} = Chat.create_message(ctx.scope, ctx.open.id, %{"body" => "mine"})

      messages =
        Chat.get_messages(ctx.scope, [
          own.id,
          ctx.hidden_message.id,
          missing_id(),
          "not-a-uuid",
          ctx.owner_message.id,
          nil
        ])

      assert Enum.map(messages, & &1.id) == [own.id, ctx.owner_message.id]
      assert Enum.all?(messages, &(&1.channel.id == ctx.open.id))
      assert Enum.all?(messages, &match?(%Message{author: %{id: _}}, &1))
    end

    test "get_messages/2 leaves out a hidden message as it does a missing one", ctx do
      assert Chat.get_messages(ctx.scope, [ctx.hidden_message.id]) == []
      assert Chat.get_messages(ctx.scope, [missing_id()]) == []
    end

    test "list_messages/3 sets each message's channel from the decision that allowed the read",
         ctx do
      assert {:ok, [message]} = Chat.list_messages(ctx.scope, ctx.open.id)
      assert message.id == ctx.owner_message.id
      assert message.channel.id == ctx.open.id
    end
  end

  defp time_out(user) do
    timeout_until = DateTime.add(DateTime.utc_now(), 3600, :second)

    Repo.update_all(from(m in Membership, where: m.user_id == ^user.id),
      set: [timeout_until: timeout_until]
    )
  end
end
