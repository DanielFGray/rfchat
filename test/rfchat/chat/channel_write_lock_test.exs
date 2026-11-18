defmodule Rfchat.Chat.ChannelWriteLockTest do
  @moduledoc """
  Channel and thread writes decide from locked state. The sandbox shares one connection, so these
  tests use real connections that commit, as `MembershipLockTest` does. A holder takes a row lock
  in an open transaction, the writes under test queue behind it, and the test releases the holder
  once `pg_locks` shows every write waiting.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  import Rfchat.ChatFixtures,
    only: [
      channel_fixture: 1,
      channel_manager_fixture: 0,
      channel_permission_overwrite_fixture: 2,
      message_fixture: 3,
      owner_fixture: 0,
      scope_for: 1,
      user_fixture: 0
    ]

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Repo

  import Rfchat.LockTestHelpers

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    assert Repo.aggregate(Rfchat.Chat.User, :count) == 0, "the test database must start empty"
    on_exit(fn -> Rfchat.TestDatabase.truncate!() end)
  end

  test "a thread is not created from a starter that a delete is removing" do
    Bootstrap.ensure_seed_data!()
    author = user_fixture()
    channel = channel_fixture(%{})
    starter = message_fixture(channel, author, %{body: "about to be deleted"})

    holder = hold_open(fn -> delete_starter_in_open_transaction(starter) end)
    creation = start(fn -> Chat.create_public_thread(scope_for(author), starter.id) end)

    await_waiters(1)
    commit(holder)

    assert {:error, :not_found} = Task.await(creation, 10_000)
    refute Repo.get_by(Channel, starter_message_id: starter.id)
  end

  test "a channel update decides from the parent a concurrent move left" do
    %{default_role: default_role} = Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    manager = channel_manager_fixture()
    channel = channel_fixture(%{})
    hidden = channel_fixture(%{kind: :category})

    channel_permission_overwrite_fixture(hidden, %{
      role_id: default_role.id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    holder = hold_open(fn -> lock_channel_row(channel.id) end)

    move =
      start(fn ->
        Chat.update_channel(scope_for(owner), channel.id, %{parent_channel_id: hidden.id})
      end)

    await_waiters(1)

    update =
      start(fn -> Chat.update_channel(scope_for(manager), channel.id, %{name: "renamed"}) end)

    await_waiters(2)
    commit(holder)

    assert {:ok, _} = Task.await(move, 10_000)
    assert {:error, :not_found} = Task.await(update, 10_000)
    refute Repo.get!(Channel, channel.id).name == "renamed"
  end

  test "a reorder and a reparent of adjacent channels both finish" do
    owner = owner_fixture()
    {channel, category} = adjacent_channel_and_category(channel_id_first: true)

    holder = hold_open(fn -> lock_channel_row(channel.id) end)
    reorder = start(fn -> Chat.move_channel(scope_for(owner), channel.id, :down) end)
    await_waiters(1)

    reparent =
      start(fn ->
        Chat.update_channel(scope_for(owner), channel.id, %{parent_channel_id: category.id})
      end)

    await_waiters(2)
    commit(holder)

    for write <- [reorder, reparent] do
      result = Task.await(write, 15_000)
      refute match?({:postgres_error, _}, result), "a write deadlocked: #{inspect(result)}"
    end
  end

  # A text channel and the category right after it, with the channel's id sorting first, so a
  # reorder that locks by id takes the channel before the category.
  defp adjacent_channel_and_category(channel_id_first: true) do
    channel = channel_fixture(%{})
    category = channel_fixture(%{kind: :category})

    if channel.id < category.id do
      {channel, category}
    else
      Repo.delete_all(from(c in Channel, where: c.id in ^[channel.id, category.id]))
      adjacent_channel_and_category(channel_id_first: true)
    end
  end

  defp delete_starter_in_open_transaction(starter) do
    Repo.update_all(from(m in Message, where: m.id == ^starter.id),
      set: [deleted_at: DateTime.utc_now(), body: "[message deleted]"]
    )
  end

  defp lock_channel_row(id) do
    Repo.one!(from(c in Channel, where: c.id == ^id, lock: "FOR UPDATE"))
  end

  # Runs `fun` on its own connection. A Postgres error becomes a value, so a deadlock the database
  # breaks shows as a failed assertion rather than as a crashed test process.
  defp start(fun) do
    Task.async(fn ->
      on_own_connection(fn ->
        try do
          fun.()
        rescue
          error in Postgrex.Error -> {:postgres_error, error.postgres.code}
        end
      end)
    end)
  end
end
