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
end
