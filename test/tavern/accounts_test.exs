defmodule Tavern.AccountsTest do
  use Tavern.DataCase, async: false

  alias Tavern.Accounts
  alias Tavern.Accounts.LoginRateLimiter
  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.Membership
  alias Tavern.Chat.User
  alias Tavern.Chat.UserSession
  alias Tavern.Repo

  import Tavern.ChatFixtures

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
    refute user.membership.is_owner
  end

  describe "promote_first_owner/1" do
    test "promotes an existing member once" do
      member = user_fixture(%{email: "owner@example.com", username: "owner_user"})

      assert {:ok, owner} = Accounts.promote_first_owner(member.email)
      assert owner.membership.is_owner
      assert {:error, :owner_exists} = Accounts.promote_first_owner(member.email)
    end

    test "returns not_found for unknown users and bots" do
      assert {:error, :not_found} = Accounts.promote_first_owner("missing@example.com")

      bot =
        %User{bot: true}
        |> User.account_changeset(%{
          email: "bot@example.com",
          username: "bot_user",
          display_name: "Bot"
        })
        |> Repo.insert!()

      %Membership{user_id: bot.id}
      |> Membership.join_changeset(DateTime.utc_now())
      |> Repo.insert!()

      assert {:error, :not_found} = Accounts.promote_first_owner(bot.email)
    end
  end

  describe "update_user_email/3" do
    test "changes the email when the current password is right" do
      user = user_fixture(%{email: "before@example.com", username: "email_right"})

      assert {:ok, updated} =
               Accounts.update_user_email(user, "supersecurepass", %{
                 "email" => "After@Example.com"
               })

      assert updated.email == "after@example.com"
      assert Repo.get!(User, user.id).email == "after@example.com"
    end

    test "writes nothing and reports the password when it is wrong" do
      user = user_fixture(%{email: "keep@example.com", username: "email_wrong"})

      assert {:error, changeset} =
               Accounts.update_user_email(user, "wrongpassword!!", %{
                 "email" => "takeover@example.com"
               })

      assert {"is not correct", _} = changeset.errors[:password]
      assert Repo.get!(User, user.id).email == "keep@example.com"
    end

    test "writes nothing when no password is given" do
      user = user_fixture(%{email: "nopass@example.com", username: "email_nopass"})

      assert {:error, changeset} =
               Accounts.update_user_email(user, nil, %{"email" => "takeover@example.com"})

      assert {"is not correct", _} = changeset.errors[:password]
      assert Repo.get!(User, user.id).email == "nopass@example.com"
    end
  end

  test "get_user_by_email_and_password/2 authenticates correctly" do
    user = user_fixture(%{email: "auth@example.com", username: "auth_user"})

    assert Accounts.get_user_by_email_and_password("auth@example.com", "supersecurepass").id ==
             user.id

    refute Accounts.get_user_by_email_and_password("auth@example.com", "wrongpass")
  end

  test "get_user_by_email_and_password/2 rejects accounts with no password hash" do
    user =
      %User{}
      |> User.account_changeset(%{
        email: "system-account@example.com",
        username: "system_account",
        display_name: "System Account"
      })
      |> Repo.insert!()

    refute Accounts.get_user_by_email_and_password(user.email, "any-password")
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
      owner = owner_fixture()
      assert Accounts.owner?(owner)
    end

    test "returns false for a regular member" do
      _owner = owner_fixture()
      member = user_fixture()
      refute Accounts.owner?(member)
    end

    test "returns false for nil" do
      refute Accounts.owner?(nil)
    end
  end

  describe "get_member/2" do
    setup do
      Bootstrap.ensure_seed_data!()
      owner = owner_fixture()
      %{owner: owner, viewer: user_fixture()}
    end

    test "returns an active member with its membership and roles", %{viewer: viewer} do
      member = user_fixture()

      assert %User{id: id, membership: %Membership{}, member_roles: roles} =
               Accounts.get_member(scope_for(viewer), member.id)

      assert id == member.id
      assert is_list(roles)
    end

    test "answers nil for a removed, banned or deleted user, an unknown id and a malformed id",
         %{owner: owner, viewer: viewer} do
      removed = user_fixture()
      banned = user_fixture()
      deleted = user_fixture()
      {:ok, _, _} = Chat.kick_member(scope_for(owner), removed.id)
      {:ok, _, _} = Chat.ban_member(scope_for(owner), banned.id)

      deleted
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      scope = scope_for(viewer)
      assert Accounts.get_member(scope, removed.id) == nil
      assert Accounts.get_member(scope, banned.id) == nil
      assert Accounts.get_member(scope, deleted.id) == nil
      assert Accounts.get_member(scope, Ecto.UUID.generate()) == nil
      assert Accounts.get_member(scope, "not-a-uuid") == nil
    end

    test "answers nil for every user when the scope is not an active member", %{
      owner: owner,
      viewer: viewer
    } do
      member = user_fixture()
      {:ok, _, _} = Chat.ban_member(scope_for(owner), viewer.id)

      assert Accounts.get_member(scope_for(viewer), member.id) == nil
    end
  end

  describe "list_members/1" do
    test "lists active members with presence, and omits removed, banned and deleted users" do
      Bootstrap.ensure_seed_data!()
      owner = owner_fixture()
      active = user_fixture()
      removed = user_fixture()
      banned = user_fixture()
      deleted = user_fixture()
      {:ok, _, _} = Chat.kick_member(scope_for(owner), removed.id)
      {:ok, _, _} = Chat.ban_member(scope_for(owner), banned.id)

      deleted
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      entries = Accounts.list_members(scope_for(active))
      ids = Enum.map(entries, & &1.user.id)

      assert owner.id in ids
      assert active.id in ids
      refute removed.id in ids
      refute banned.id in ids
      refute deleted.id in ids
      assert Enum.all?(entries, &(&1.status in [:online, :recent, :offline]))
    end

    test "is empty for a scope that is not an active member" do
      Bootstrap.ensure_seed_data!()
      owner = owner_fixture()
      viewer = user_fixture()
      {:ok, _, _} = Chat.ban_member(scope_for(owner), viewer.id)

      assert Accounts.list_members(scope_for(viewer)) == []
    end
  end

  describe "promote_to_owner/2" do
    test "owner can promote a regular member" do
      owner = owner_fixture()
      member = user_fixture()

      member = user_with_membership!(member.id)
      refute member.membership.is_owner

      assert {:ok, membership} = Accounts.promote_to_owner(scope_for(owner), member.id)
      assert membership.is_owner
    end

    test "non-owner cannot promote anyone" do
      _owner = owner_fixture()
      member_a = user_fixture()
      member_b = user_fixture()

      member_a = user_with_membership!(member_a.id)
      member_b = user_with_membership!(member_b.id)

      assert {:error, :forbidden} = Accounts.promote_to_owner(scope_for(member_a), member_b.id)
    end

    test "owner cannot promote themselves" do
      owner = owner_fixture()
      assert {:error, :self} = Accounts.promote_to_owner(scope_for(owner), owner.id)
    end

    test "a banned member, or an id with no membership, answers like a missing member" do
      owner = owner_fixture()
      member = user_fixture()
      {:ok, _member, _case} = Chat.ban_member(scope_for(owner), member.id)

      assert {:error, :not_found} = Accounts.promote_to_owner(scope_for(owner), member.id)
      assert {:error, :not_found} = Accounts.demote_from_owner(scope_for(owner), member.id)

      assert {:error, :not_found} =
               Accounts.promote_to_owner(scope_for(owner), Ecto.UUID.generate())
    end

    test "multiple owners can coexist" do
      owner = owner_fixture()
      member = user_fixture()

      member = user_with_membership!(member.id)
      assert {:ok, _membership} = Accounts.promote_to_owner(scope_for(owner), member.id)

      # Both are now owners
      assert Accounts.owner?(user_with_membership!(owner.id))
      assert Accounts.owner?(user_with_membership!(member.id))
    end
  end

  describe "demote_from_owner/2" do
    test "owner can demote another owner" do
      owner = owner_fixture()
      member = user_fixture()

      member = user_with_membership!(member.id)
      {:ok, _} = Accounts.promote_to_owner(scope_for(owner), member.id)

      member = user_with_membership!(member.id)
      assert member.membership.is_owner

      assert {:ok, membership} = Accounts.demote_from_owner(scope_for(owner), member.id)
      refute membership.is_owner
    end

    test "owner cannot demote themselves" do
      owner = owner_fixture()
      assert {:error, :self} = Accounts.demote_from_owner(scope_for(owner), owner.id)
    end

    test "non-owner cannot demote anyone" do
      _owner = owner_fixture()
      member = user_fixture()

      member = user_with_membership!(member.id)
      assert {:error, :forbidden} = Accounts.demote_from_owner(scope_for(member), member.id)
    end
  end
end
