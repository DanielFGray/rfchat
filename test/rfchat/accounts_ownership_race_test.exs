defmodule Rfchat.AccountsOwnershipRaceTest do
  @moduledoc """
  Ownership races need two real database connections that commit, so these tests leave the
  sandbox and delete the users they made when they finish. Each test holds one ownership
  change open in a transaction and starts a second change on another connection. With the
  ownership lock, the second change waits and then reads the first one's committed result.
  Without it, the second change finishes at once from a stale read.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Rfchat.Accounts
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  # How long the second change gets to finish while the first is open. A correct lock never
  # lets it finish, so this time only bounds how fast a missing lock is detected.
  @blocked_ms 2_000

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    assert Repo.aggregate(User, :count) == 0, "the test database must start empty"

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(User)
    end)
  end

  test "concurrent first promotions leave exactly one owner" do
    {:ok, first_user} = Accounts.register_user(user_attrs())
    {:ok, second_user} = Accounts.register_user(user_attrs())
    first = hold_open(fn -> Accounts.promote_first_owner(first_user.email) end)

    second =
      Task.async(fn ->
        on_own_connection(fn -> Accounts.promote_first_owner(second_user.email) end)
      end)

    assert Task.yield(second, @blocked_ms) == nil, "the second promotion did not wait"
    assert {:ok, %User{}} = commit(first)
    assert {:error, :owner_exists} = Task.await(second)

    assert owner_count() == 1
  end

  test "two owners demoting each other at once leave one owner" do
    {:ok, alice} = Accounts.register_user(user_attrs())
    {:ok, bob} = Accounts.register_user(user_attrs())
    {:ok, alice} = Accounts.promote_first_owner(alice.email)
    {:ok, _} = Accounts.promote_to_owner(alice, bob)

    first = hold_open(fn -> Accounts.demote_from_owner(alice, bob) end)

    second =
      Task.async(fn -> on_own_connection(fn -> Accounts.demote_from_owner(bob, alice) end) end)

    assert Task.yield(second, @blocked_ms) == nil, "the second demotion did not wait"
    assert {:ok, %Membership{is_owner: false}} = commit(first)
    assert {:error, :forbidden} = Task.await(second)

    assert owner_count() == 1
  end

  # Runs `fun` inside a transaction on its own connection and keeps the transaction open
  # until `commit/1`. Returns the holder process.
  defp hold_open(fun) do
    parent = self()

    holder =
      spawn_link(fn ->
        on_own_connection(fn ->
          Repo.transaction(fn ->
            send(parent, {:held, self(), fun.()})
            receive do: (:commit -> :ok)
          end)
        end)

        send(parent, {:committed, self()})
      end)

    assert_receive {:held, ^holder, result}, 10_000
    {holder, result}
  end

  defp commit({holder, result}) do
    send(holder, :commit)
    assert_receive {:committed, ^holder}, 10_000
    result
  end

  defp on_own_connection(fun) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    fun.()
  end

  defp owner_count do
    Repo.aggregate(from(m in Membership, where: m.is_owner), :count)
  end

  defp user_attrs do
    name = "race_#{System.unique_integer([:positive])}"

    %{
      email: "#{name}@example.com",
      username: name,
      display_name: name,
      password: "supersecurepass"
    }
  end
end
