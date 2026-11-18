defmodule Rfchat.Chat.RoleLockTest do
  @moduledoc """
  Moderation and bot role grants decide from the role order a concurrent role write leaves. The sandbox shares one
  connection, so this test uses real connections that commit, as `ChannelWriteLockTest` does.
  """
  use ExUnit.Case, async: false

  import Rfchat.ChatFixtures,
    only: [
      member_role_fixture: 2,
      owner_fixture: 0,
      role_fixture: 1,
      scope_for: 1,
      user_fixture: 0
    ]

  import Rfchat.LockTestHelpers

  alias Rfchat.Bots
  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    assert Repo.aggregate(Rfchat.Chat.User, :count) == 0, "the test database must start empty"
    on_exit(fn -> Rfchat.TestDatabase.truncate!() end)
  end

  test "a moderation waits for a role move and decides from the order it left" do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()

    moderator_role =
      role_fixture(%{position: 20, permissions: PermissionBits.combine([:moderate_members])})

    subject_role = role_fixture(%{position: 10})
    moderator = user_fixture()
    subject = user_fixture()
    member_role_fixture(moderator, moderator_role)
    member_role_fixture(subject, subject_role)

    holder = hold_open(fn -> Chat.move_role(scope_for(owner), subject_role.id, :up) end)

    timeout =
      Task.async(fn ->
        on_own_connection(fn -> Chat.timeout_member(scope_for(moderator), subject.id, 10) end)
      end)

    await_waiters(1)
    commit(holder)

    assert {:error, :forbidden} = Task.await(timeout, 10_000)
  end

  test "a bot grant waits for a role move and decides from the order it left" do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()

    manager_role =
      role_fixture(%{
        position: 20,
        permissions: PermissionBits.combine([:manage_bots, :manage_roles])
      })

    granted_role = role_fixture(%{position: 10})
    manager = user_fixture()
    member_role_fixture(manager, manager_role)

    holder = hold_open(fn -> Chat.move_role(scope_for(owner), granted_role.id, :up) end)

    attrs = %{
      "username" => "bot_lock_grant",
      "display_name" => "Lock bot",
      "email" => "bot_lock_grant@example.com",
      "role_ids" => [granted_role.id]
    }

    creation = Task.async(fn -> on_own_connection(fn -> Bots.create_bot(attrs, manager) end) end)

    await_waiters(1)
    commit(holder)

    assert {:error, :forbidden} = Task.await(creation, 10_000)
  end
end
