defmodule Rfchat.Chat.MembershipLockTest do
  @moduledoc """
  A write takes its actor's membership row `FOR SHARE` before it decides. The sandbox shares one
  connection, so these tests use real connections that commit, as the ownership race tests do.
  A holder runs `authorize_write/3` in a transaction and stays open. A second connection then
  asks for the row `FOR UPDATE`, which is what a ban or timeout does, and must wait.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.User
  alias Rfchat.Chat.Visibility
  alias Rfchat.Repo

  # A correct lock never lets the second request through while the holder is open, so the
  # timeout bounds how fast a missing lock shows up.
  @lock_timeout "300ms"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    assert Repo.aggregate(User, :count) == 0, "the test database must start empty"

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(User)
    end)
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
