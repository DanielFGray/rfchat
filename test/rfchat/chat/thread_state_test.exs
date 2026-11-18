defmodule Rfchat.Chat.ThreadStateTest do
  @moduledoc """
  A locked or archived thread, and a channel with slowmode, refuse the writes the rules name:
  locked threads take writes from `manage_messages` holders only, an ordinary send reopens an
  archived thread, and slowmode allows one message per window per author.
  """
  use Rfchat.DataCase, async: false

  import Ecto.Changeset, only: [change: 2]
  import Rfchat.ChatFixtures

  alias Rfchat.Chat
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Repo

  @member_bits [
    :view_channel,
    :send_messages,
    :send_messages_in_threads,
    :add_reactions,
    :create_public_threads
  ]

  setup do
    _owner = owner_fixture()
    member_role = role_fixture(%{permissions: PermissionBits.combine(@member_bits)})

    moderator_role =
      role_fixture(%{permissions: PermissionBits.combine([:manage_messages | @member_bits])})

    creator = user_fixture()
    member = user_fixture()
    moderator = user_fixture()
    member_role_fixture(creator, member_role)
    member_role_fixture(member, member_role)
    member_role_fixture(moderator, moderator_role)

    channel = channel_fixture(%{})
    starter = message_fixture(channel, moderator, %{body: "starter"})
    thread = thread_fixture(channel, starter, creator)

    %{
      channel: channel,
      thread: thread,
      creator: creator,
      member: member,
      moderator: moderator,
      reply: message_fixture(thread, member, %{body: "a reply"})
    }
  end

  describe "locked thread" do
    test "refuses send, react, edit and delete from a member", ctx do
      lock!(ctx.thread)
      member = scope_for(ctx.member)

      assert {:error, :forbidden} = Chat.create_message(member, ctx.thread.id, %{body: "hi"})
      assert {:error, :forbidden} = Chat.toggle_reaction(member, ctx.reply.id, "👍")
      assert {:error, :forbidden} = Chat.update_message(member, ctx.reply.id, %{body: "edit"})
      assert {:error, :forbidden} = Chat.delete_message(member, ctx.reply.id)
    end

    test "lets a manage_messages holder send, react, edit and delete", ctx do
      lock!(ctx.thread)
      moderator = scope_for(ctx.moderator)

      assert {:ok, own} = Chat.create_message(moderator, ctx.thread.id, %{body: "hi"})
      assert {:ok, _} = Chat.toggle_reaction(moderator, ctx.reply.id, "👍")
      assert {:ok, _} = Chat.update_message(moderator, own.id, %{body: "edit"})
      assert {:ok, _} = Chat.delete_message(moderator, ctx.reply.id)
    end

    test "only a manager unarchives it", ctx do
      lock!(ctx.thread)
      archive!(ctx.thread)

      assert {:error, :forbidden} = Chat.unarchive_thread(scope_for(ctx.creator), ctx.thread.id)
      assert {:ok, thread} = Chat.unarchive_thread(scope_for(ctx.moderator), ctx.thread.id)
      assert is_nil(thread.archived_at)
    end
  end

  describe "archived thread" do
    test "a member's send unarchives it in the same write", ctx do
      archive!(ctx.thread)

      assert {:ok, _message} =
               Chat.create_message(scope_for(ctx.member), ctx.thread.id, %{body: "hi"})

      assert is_nil(Repo.get!(Channel, ctx.thread.id).archived_at)
    end

    test "a refused send leaves it archived", ctx do
      archive!(ctx.thread)
      no_send = user_fixture()

      assert {:error, _} = Chat.create_message(scope_for(no_send), ctx.thread.id, %{body: "hi"})
      assert Repo.get!(Channel, ctx.thread.id).archived_at
    end

    test "refuses react, edit and delete from a member but not a manager", ctx do
      archive!(ctx.thread)
      member = scope_for(ctx.member)

      assert {:error, :forbidden} = Chat.toggle_reaction(member, ctx.reply.id, "👍")
      assert {:error, :forbidden} = Chat.update_message(member, ctx.reply.id, %{body: "edit"})
      assert {:error, :forbidden} = Chat.delete_message(member, ctx.reply.id)
      assert {:ok, _} = Chat.toggle_reaction(scope_for(ctx.moderator), ctx.reply.id, "👍")
    end
  end

  describe "thread controls" do
    test "the creator or a manager archives and unarchives", ctx do
      assert {:ok, %{archived_at: %DateTime{}}} =
               Chat.archive_thread(scope_for(ctx.creator), ctx.thread.id)

      assert {:ok, %{archived_at: nil}} =
               Chat.unarchive_thread(scope_for(ctx.creator), ctx.thread.id)

      assert {:ok, %{archived_at: %DateTime{}}} =
               Chat.archive_thread(scope_for(ctx.moderator), ctx.thread.id)
    end

    test "another member may not archive", ctx do
      assert {:error, :forbidden} = Chat.archive_thread(scope_for(ctx.member), ctx.thread.id)
    end

    test "only a manager locks and unlocks", ctx do
      assert {:error, :forbidden} = Chat.lock_thread(scope_for(ctx.creator), ctx.thread.id)

      assert {:ok, %{locked_at: %DateTime{}}} =
               Chat.lock_thread(scope_for(ctx.moderator), ctx.thread.id)

      assert {:error, :forbidden} = Chat.unlock_thread(scope_for(ctx.creator), ctx.thread.id)

      assert {:ok, %{locked_at: nil}} =
               Chat.unlock_thread(scope_for(ctx.moderator), ctx.thread.id)
    end

    test "a channel is not a thread", ctx do
      assert {:error, :forbidden} = Chat.lock_thread(scope_for(ctx.moderator), ctx.channel.id)
    end
  end

  describe "slowmode" do
    setup ctx do
      ctx.channel |> change(slowmode_seconds: 60) |> Repo.update!()
      :ok
    end

    test "refuses a second send inside the window with the seconds left", ctx do
      member = scope_for(ctx.member)

      assert {:ok, _} = Chat.create_message(member, ctx.channel.id, %{body: "one"})

      assert {:error, {:slowmode, left}} =
               Chat.create_message(member, ctx.channel.id, %{body: "two"})

      assert left in 1..60
    end

    test "counts each author on their own", ctx do
      assert {:ok, _} = Chat.create_message(scope_for(ctx.member), ctx.channel.id, %{body: "one"})

      assert {:ok, _} =
               Chat.create_message(scope_for(ctx.creator), ctx.channel.id, %{body: "two"})
    end

    test "allows a send once the window has passed", ctx do
      member = scope_for(ctx.member)
      assert {:ok, first} = Chat.create_message(member, ctx.channel.id, %{body: "one"})

      first
      |> change(inserted_at: DateTime.add(first.inserted_at, -61, :second))
      |> Repo.update!()

      assert {:ok, _} = Chat.create_message(member, ctx.channel.id, %{body: "two"})
    end

    test "a deleted message still counts", ctx do
      member = scope_for(ctx.member)
      assert {:ok, first} = Chat.create_message(member, ctx.channel.id, %{body: "one"})
      assert {:ok, _} = Chat.delete_message(member, first.id)

      assert {:error, {:slowmode, _}} =
               Chat.create_message(member, ctx.channel.id, %{body: "two"})
    end

    test "exempts manage_messages and manage_channels", ctx do
      moderator = scope_for(ctx.moderator)
      assert {:ok, _} = Chat.create_message(moderator, ctx.channel.id, %{body: "one"})
      assert {:ok, _} = Chat.create_message(moderator, ctx.channel.id, %{body: "two"})

      manager = channel_manager_fixture()

      member_role_fixture(
        manager,
        role_fixture(%{permissions: PermissionBits.combine(@member_bits)})
      )

      assert {:ok, _} = Chat.create_message(scope_for(manager), ctx.channel.id, %{body: "one"})
      assert {:ok, _} = Chat.create_message(scope_for(manager), ctx.channel.id, %{body: "two"})
    end

    test "applies in a thread", ctx do
      ctx.thread |> change(slowmode_seconds: 60) |> Repo.update!()
      member = scope_for(ctx.creator)

      assert {:ok, _} = Chat.create_message(member, ctx.thread.id, %{body: "one"})
      assert {:error, {:slowmode, _}} = Chat.create_message(member, ctx.thread.id, %{body: "two"})
    end
  end

  defp lock!(thread), do: thread |> change(locked_at: DateTime.utc_now()) |> Repo.update!()
  defp archive!(thread), do: thread |> change(archived_at: DateTime.utc_now()) |> Repo.update!()
end
