defmodule Rfchat.Chat.MembershipLockTest do
  @moduledoc """
  A write takes its actor's membership row `FOR SHARE` before it decides. The sandbox shares one
  connection, so these tests use real connections that commit, as the ownership race tests do.
  A holder runs `authorize_write/3` in a transaction and stays open. A second connection then
  asks for the row `FOR UPDATE`, which is what a ban or timeout does, and must wait.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  import Rfchat.ChatFixtures, only: [role_fixture: 1, member_role_fixture: 2, scope_for: 1]

  alias Rfchat.Accounts
  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.User
  alias Rfchat.Chat.Visibility
  alias Rfchat.Repo

  # A correct lock never lets the second request through while the holder is open, so the
  # timeout bounds how fast a missing lock shows up.
  @lock_timeout "300ms"

  # Backends blocked on a row lock. A row-lock wait is an ungranted `transactionid` lock in
  # `pg_locks`, which every role may read. `pg_stat_activity` hides other sessions' queries and wait
  # events from a non-superuser role, so it cannot show this wait.
  @waiting_sql """
  SELECT count(*) FROM pg_locks
  WHERE NOT granted AND locktype = 'transactionid' AND pid <> pg_backend_pid()
  """

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    assert Repo.aggregate(User, :count) == 0, "the test database must start empty"

    # These tests commit moderation cases, audit rows and roles, which reference users, so the
    # cleanup truncates every table rather than deleting users alone.
    on_exit(fn -> Rfchat.TestDatabase.truncate!() end)
  end

  test "authorize_write/3 raises outside a transaction" do
    user = register_user()
    channel = %Channel{id: Ecto.UUID.generate()}

    assert_raise ArgumentError, ~r/must run inside a transaction/, fn ->
      Visibility.authorize_write(%Scope{user_id: user.id}, :send_messages, channel)
    end
  end

  test "a write's decision holds the actor's membership row against a moderation lock" do
    user = register_user()
    scope = %Scope{user_id: user.id}
    channel = %Channel{id: Ecto.UUID.generate()}

    holder = hold_open(fn -> Visibility.authorize_write(scope, :send_messages, channel) end)

    assert {:lock_not_available, :lock_not_available} =
             from_other_connection(fn -> try_moderation_lock(user.id) end),
           "the moderation lock was granted while the write held the membership row"

    commit(holder)
  end

  test "without a write holding the row, the moderation lock is granted at once" do
    user = register_user()

    assert :granted = from_other_connection(fn -> try_moderation_lock(user.id) end)
  end

  # The holder makes the subject an owner and stays open. The ban cannot read that change until the
  # holder commits, so the ban must wait on the subject's row and then decide on the committed owner.
  test "a ban waiting on a subject who becomes an owner answers :forbidden when the actor id sorts first" do
    {actor, subject} = moderator_and_subject(actor_first?: true)

    holder = hold_open(fn -> make_owner_in_open_transaction(subject) end)
    ban = start_ban(actor, subject)

    await_lock_wait()
    commit(holder)

    assert {:error, :forbidden} = Task.await(ban, 10_000)
  end

  test "a ban waiting on a subject who becomes an owner answers :forbidden when the subject id sorts first" do
    {actor, subject} = moderator_and_subject(actor_first?: false)

    holder = hold_open(fn -> make_owner_in_open_transaction(subject) end)
    ban = start_ban(actor, subject)

    await_lock_wait()
    commit(holder)

    assert {:error, :forbidden} = Task.await(ban, 10_000)
  end

  # Owners cannot be moderated through the API, so the holder deactivates the actor directly. The
  # promotion must wait on the actor's row and then see that the actor is no longer an active owner.
  test "a promotion waiting on an owner who is deactivated answers :forbidden" do
    actor = register_user()
    subject = register_user()
    {:ok, _owner} = Accounts.promote_first_owner(actor.email)

    holder = hold_open(fn -> deactivate_in_open_transaction(actor) end)

    promotion =
      Task.async(fn ->
        on_own_connection(fn ->
          Accounts.promote_to_owner(%Scope{user_id: actor.id}, subject.id)
        end)
      end)

    await_lock_wait()
    commit(holder)

    assert {:error, :forbidden} = Task.await(promotion, 10_000)
  end

  defp start_ban(actor, subject) do
    Task.async(fn ->
      on_own_connection(fn -> Chat.ban_member(scope_for(actor), subject.id) end)
    end)
  end

  # Two members with a role that grants ban_members and outranks the subject. The lower user id is
  # the actor when `actor_first?` is true, otherwise the subject.
  defp moderator_and_subject(actor_first?: actor_first?) do
    first = register_user()
    second = register_user()
    {low, high} = if first.id < second.id, do: {first, second}, else: {second, first}
    {actor, subject} = if actor_first?, do: {low, high}, else: {high, low}

    role =
      role_fixture(%{
        name: "lock_role_#{System.unique_integer([:positive])}",
        permissions: PermissionBits.combine([:ban_members]),
        position: 50
      })

    member_role_fixture(actor, role)
    {actor, subject}
  end

  defp make_owner_in_open_transaction(user) do
    user.id
    |> locked_membership()
    |> Membership.ownership_changeset(true)
    |> Repo.update!()
  end

  defp deactivate_in_open_transaction(user) do
    user.id
    |> locked_membership()
    |> Membership.deactivate_changeset(DateTime.utc_now(), %{"banned" => true})
    |> Repo.update!()
  end

  defp locked_membership(user_id) do
    Repo.one!(from(m in Membership, where: m.user_id == ^user_id, lock: "FOR UPDATE"))
  end

  # Polls the waiting-lock count until one backend is blocked on a `FOR UPDATE`. Each poll is a
  # network round trip, so the bound is in attempts rather than a sleep.
  defp await_lock_wait(attempts \\ 100)

  defp await_lock_wait(0), do: flunk("no backend waited on a membership row lock")

  defp await_lock_wait(attempts) do
    case Repo.query!(@waiting_sql).rows do
      [[0]] -> await_lock_wait(attempts - 1)
      [[_waiting]] -> :ok
    end
  end

  # Runs `fun` inside a transaction on its own connection and keeps the transaction open until
  # `commit/1`. Returns the holder process, which `commit/1` waits on.
  defp hold_open(fun) do
    parent = self()

    holder =
      spawn_link(fn ->
        on_own_connection(fn ->
          result =
            Repo.transaction(fn ->
              send(parent, {:held, self(), fun.()})
              receive do: (:commit -> :ok)
            end)

          send(parent, {:committed, self(), result})
        end)
      end)

    assert_receive {:held, ^holder, _decision}, 10_000
    holder
  end

  defp commit(holder) do
    send(holder, :commit)
    assert_receive {:committed, ^holder, {:ok, _}}, 10_000
  end

  # A `FOR UPDATE` on the membership row with a short lock timeout. Returns :granted when the row
  # is free, or {:lock_not_available, code} when the request had to wait past the timeout.
  defp try_moderation_lock(user_id) do
    {:ok, :granted} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '#{@lock_timeout}'")

        Repo.one(from(m in Membership, where: m.user_id == ^user_id, lock: "FOR UPDATE"))

        :granted
      end)

    :granted
  rescue
    error in Postgrex.Error -> {:lock_not_available, error.postgres.code}
  end

  # Runs `fun` in a new process, which checks out its own connection. The test process already holds
  # one from the sandbox setup, so a checkout there would return the existing connection.
  defp from_other_connection(fun) do
    Task.async(fn -> on_own_connection(fun) end) |> Task.await(10_000)
  end

  defp on_own_connection(fun) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    fun.()
  end

  defp register_user do
    name = "lock_#{System.unique_integer([:positive])}"

    {:ok, user} =
      Rfchat.Accounts.register_user(%{
        email: "#{name}@example.com",
        username: name,
        display_name: name,
        password: "supersecurepass"
      })

    user
  end
end
