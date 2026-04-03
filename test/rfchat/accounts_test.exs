defmodule Rfchat.AccountsTest do
  use Rfchat.DataCase, async: false

  alias Rfchat.Accounts
  alias Rfchat.Accounts.LoginRateLimiter
  alias Rfchat.Chat.UserSession
  alias Rfchat.Repo

  import Rfchat.ChatFixtures

  setup do
    LoginRateLimiter.reset!()
    :ok
  end

  test "register_user/1 creates a member account with hashed password" do
    assert {:ok, user} =
             Accounts.register_user(%{
               email: "new@example.com",
               username: "new_user",
               display_name: "New User",
               password: "supersecurepass"
             })

    assert user.email == "new@example.com"
    assert user.hashed_password
    assert user.membership.user_id == user.id
    assert user.membership.is_owner
  end

  test "only the first registered account becomes owner" do
    assert {:ok, first_user} =
             Accounts.register_user(%{
               email: "owner@example.com",
               username: "owner_user",
               display_name: "Owner User",
               password: "supersecurepass"
             })

    assert {:ok, second_user} =
             Accounts.register_user(%{
               email: "member@example.com",
               username: "member_user",
               display_name: "Member User",
               password: "supersecurepass"
             })

    assert first_user.membership.is_owner
    refute second_user.membership.is_owner
  end

  test "get_user_by_email_and_password/2 authenticates correctly" do
    user = user_fixture(%{email: "auth@example.com", username: "auth_user"})

    assert Accounts.get_user_by_email_and_password("auth@example.com", "supersecurepass").id ==
             user.id

    refute Accounts.get_user_by_email_and_password("auth@example.com", "wrongpass")
  end

  test "session token roundtrip resolves current user" do
    user = user_fixture()

    token =
      Accounts.generate_user_session_token(user, %{
        ip_address: "127.0.0.1",
        user_agent: "ExUnit"
      })

    session = Repo.get_by!(UserSession, token_hash: Accounts.hash_token(token))
    assert session.ip_address == "127.0.0.1"
    assert session.user_agent == "ExUnit"

    old_seen_at = DateTime.add(DateTime.utc_now(), -3_600, :second)
    session |> Ecto.Changeset.change(last_seen_at: old_seen_at) |> Repo.update!()

    assert Accounts.get_user_by_session_token(token).id == user.id

    assert Repo.get_by!(UserSession, token_hash: Accounts.hash_token(token)).last_seen_at >
             old_seen_at

    assert :ok = Accounts.delete_user_session_token(token)
    refute Accounts.get_user_by_session_token(token)
  end

  describe "owner?/1" do
    test "returns true for an owner" do
      owner = user_fixture()
      assert Accounts.owner?(owner)
    end

    test "returns false for a regular member" do
      _owner = user_fixture()
      member = user_fixture()
      refute Accounts.owner?(member)
    end

    test "returns false for nil" do
      refute Accounts.owner?(nil)
    end
  end

  describe "promote_to_owner/2" do
    test "owner can promote a regular member" do
      owner = user_fixture()
      member = user_fixture()

      member = Accounts.get_user_with_membership!(member.id)
      refute member.membership.is_owner

      assert {:ok, membership} = Accounts.promote_to_owner(owner, member)
      assert membership.is_owner
    end

    test "non-owner cannot promote anyone" do
      _owner = user_fixture()
      member_a = user_fixture()
      member_b = user_fixture()

      member_a = Accounts.get_user_with_membership!(member_a.id)
      member_b = Accounts.get_user_with_membership!(member_b.id)

      assert {:error, :forbidden} = Accounts.promote_to_owner(member_a, member_b)
    end

    test "owner cannot promote themselves" do
      owner = user_fixture()
      assert {:error, :self} = Accounts.promote_to_owner(owner, owner)
    end

    test "multiple owners can coexist" do
      owner = user_fixture()
      member = user_fixture()

      member = Accounts.get_user_with_membership!(member.id)
      assert {:ok, _membership} = Accounts.promote_to_owner(owner, member)

      # Both are now owners
      assert Accounts.owner?(Accounts.get_user_with_membership!(owner.id))
      assert Accounts.owner?(Accounts.get_user_with_membership!(member.id))
    end
  end

  describe "demote_from_owner/2" do
    test "owner can demote another owner" do
      owner = user_fixture()
      member = user_fixture()

      member = Accounts.get_user_with_membership!(member.id)
      {:ok, _} = Accounts.promote_to_owner(owner, member)

      member = Accounts.get_user_with_membership!(member.id)
      assert member.membership.is_owner

      assert {:ok, membership} = Accounts.demote_from_owner(owner, member)
      refute membership.is_owner
    end

    test "owner cannot demote themselves" do
      owner = user_fixture()
      assert {:error, :self} = Accounts.demote_from_owner(owner, owner)
    end

    test "non-owner cannot demote anyone" do
      _owner = user_fixture()
      member = user_fixture()

      member = Accounts.get_user_with_membership!(member.id)
      assert {:error, :forbidden} = Accounts.demote_from_owner(member, member)
    end
  end
end
