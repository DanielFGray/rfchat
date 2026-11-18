defmodule RfchatWeb.SettingsLiveTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rfchat.Accounts
  alias Rfchat.Accounts.LoginRateLimiter
  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.User
  alias Rfchat.Repo
  import Rfchat.ChatFixtures

  describe "profile save" do
    test "saves name, username and bio, and ignores asset ids and email", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      user = user_fixture(%{email: "profile-me@example.com", username: "profile_me"})
      other = user_fixture(%{email: "profile-other@example.com", username: "profile_other"})
      other_asset = media_asset_fixture(other)

      {:ok, view, _html} = live(log_in_as(conn, user), ~p"/settings?tab=profile")

      render_submit(view, "save_profile", %{
        "user" => %{
          "display_name" => "Renamed",
          "username" => "renamed_me",
          "bio" => "New bio",
          "email" => "hijack@example.com",
          "avatar_asset_id" => other_asset.id,
          "banner_asset_id" => other_asset.id
        }
      })

      reloaded = Repo.get!(User, user.id)
      assert reloaded.display_name == "Renamed"
      assert reloaded.username == "renamed_me"
      assert reloaded.bio == "New bio"
      assert reloaded.email == "profile-me@example.com"
      assert is_nil(reloaded.avatar_asset_id)
      assert is_nil(reloaded.banner_asset_id)
    end

    test "the profile form has no email input and the email form is present", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      user = user_fixture(%{email: "form-me@example.com", username: "form_me"})

      {:ok, view, _html} = live(log_in_as(conn, user), ~p"/settings?tab=profile")

      refute has_element?(view, "#profile-form input[name='user[email]']")
      assert has_element?(view, "#email-form input[name='email_change[password]']")
    end

    test "the email form keeps the old email when the password is wrong", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      user = user_fixture(%{email: "keep-me@example.com", username: "keep_me"})

      {:ok, view, _html} = live(log_in_as(conn, user), ~p"/settings?tab=profile")

      view
      |> form("#email-form", %{
        "email_change" => %{"email" => "takeover@example.com", "password" => "wrongpassword!!"}
      })
      |> render_submit()

      assert has_element?(view, "#email-form")
      assert render(view) =~ "is not correct"
      assert Repo.get!(User, user.id).email == "keep-me@example.com"
    end

    test "the email form changes the email when the password is right", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      user = user_fixture(%{email: "move-me@example.com", username: "move_me"})

      {:ok, view, _html} = live(log_in_as(conn, user), ~p"/settings?tab=profile")

      view
      |> form("#email-form", %{
        "email_change" => %{"email" => "moved@example.com", "password" => "supersecurepass"}
      })
      |> render_submit()

      assert render(view) =~ "Email updated."
      assert Repo.get!(User, user.id).email == "moved@example.com"
    end

    test "the email form blocks password checks after the credential limit", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      user = user_fixture(%{email: "limited-email@example.com", username: "limited_email"})

      Enum.each(1..5, fn _attempt ->
        :ok = LoginRateLimiter.check_attempt("127.0.0.1", user.email)
      end)

      {:ok, view, _html} = live(log_in_as(conn, user), ~p"/settings?tab=profile")

      view
      |> form("#email-form", %{
        "email_change" => %{"email" => "changed@example.com", "password" => "supersecurepass"}
      })
      |> render_submit()

      assert render(view) =~ "Too many attempts. Try again in"
      assert Repo.get!(User, user.id).email == user.email
    end
  end

  describe "owner promote/demote" do
    test "owner sees Owner badge and Promote button for members", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      {conn, _owner, member} = log_in_owner_with_member(conn)

      {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

      # Owner badge on the owner's row
      assert has_element?(view, "#member-presence-#{current_user_from_conn(conn).id}")

      # Promote button on the member's row
      assert has_element?(view, "#promote-owner-#{member.id}")

      # No demote button on the member (not an owner)
      refute has_element?(view, "#demote-owner-#{member.id}")
    end

    test "member does not see promote/demote buttons", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      {conn, owner, _member} = log_in_member_with_owner(conn)

      {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

      refute has_element?(view, "#promote-owner-#{owner.id}")
      refute has_element?(view, "#demote-owner-#{owner.id}")
    end

    test "owner can promote a member to owner", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      {conn, _owner, member} = log_in_owner_with_member(conn)

      {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

      view |> element("#promote-owner-#{member.id}") |> render_click()

      # After promotion, the member should have the Owner badge
      html = render(view)
      assert html =~ "is now an owner"

      # Demote button should now appear
      assert has_element?(view, "#demote-owner-#{member.id}")

      # Promote button should be gone
      refute has_element?(view, "#promote-owner-#{member.id}")
    end

    test "owner can demote another owner", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      {conn, _owner, member} = log_in_owner_with_member(conn)

      # First promote the member
      member_with_membership = user_with_membership!(member.id)
      owner_user = current_user_from_conn(conn)
      {:ok, _} = Accounts.promote_to_owner(scope_for(owner_user), member_with_membership.id)

      {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

      assert has_element?(view, "#demote-owner-#{member.id}")

      view |> element("#demote-owner-#{member.id}") |> render_click()

      html = render(view)
      assert html =~ "is no longer an owner"

      # Promote button should reappear
      assert has_element?(view, "#promote-owner-#{member.id}")

      # Demote button should be gone
      refute has_element?(view, "#demote-owner-#{member.id}")
    end

    test "owner does not see promote/demote buttons on their own row", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      {conn, _owner, _member} = log_in_owner_with_member(conn)

      {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

      owner_id = current_user_from_conn(conn).id

      refute has_element?(view, "#promote-owner-#{owner_id}")
      refute has_element?(view, "#demote-owner-#{owner_id}")
    end
  end

  describe "moderation case list" do
    setup do
      Bootstrap.ensure_seed_data!()
      owner = owner_fixture(%{email: "case-owner@example.com", username: "case_owner"})
      target = user_fixture(%{email: "case-target@example.com", username: "case_target"})
      {:ok, _timed_out, _case} = Chat.timeout_member(scope_for(owner), target.id, 10)
      %{target: target}
    end

    test "a moderator without view_audit_log sees no case list", %{conn: conn, target: target} do
      moderator = moderator_with([:kick_members], "case_kick")
      {:ok, view, _html} = live(log_in_as(conn, moderator), ~p"/settings?tab=server")

      render_click(element(view, "#open-member-actions-#{target.id}"))

      assert has_element?(view, "#member-actions-#{target.id}")
      refute has_element?(view, "#moderation-cases")
    end

    test "a moderator with view_audit_log sees the case list", %{conn: conn, target: target} do
      auditor = moderator_with([:kick_members, :view_audit_log], "case_audit")
      {:ok, view, _html} = live(log_in_as(conn, auditor), ~p"/settings?tab=server")

      render_click(element(view, "#open-member-actions-#{target.id}"))

      assert has_element?(view, "#moderation-cases")
    end
  end

  defp moderator_with(permissions, username) do
    moderator = user_fixture(%{email: "#{username}@example.com", username: username})

    member_role_fixture(
      moderator,
      role_fixture(%{permissions: PermissionBits.combine(permissions), position: 50})
    )

    moderator
  end

  describe "bot registry visibility" do
    test "a manager sees only the bots it can control", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      owner = owner_fixture(%{email: "bot-reg-owner@example.com", username: "bot_reg_owner"})
      high_role = role_fixture(%{permissions: 0, position: 10})
      high_bot = bot_fixture(owner, %{"role_ids" => [high_role.id]})
      low_bot = bot_fixture(owner, %{})

      manager_role =
        role_fixture(%{permissions: PermissionBits.combine([:manage_bots]), position: 5})

      manager = user_fixture(%{email: "bot-reg-manager@example.com", username: "bot_reg_manager"})
      member_role_fixture(manager, manager_role)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, Accounts.generate_user_session_token(manager))
        |> Plug.Conn.put_session(:live_socket_id, "users_sessions:bot-reg-manager")

      {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

      assert has_element?(view, "#bot-card-#{low_bot.id}")
      refute has_element?(view, "#bot-card-#{high_bot.id}")
    end
  end

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end

  defp log_in_owner_with_member(conn) do
    owner =
      owner_fixture(%{
        email: "settings-owner@example.com",
        username: "settings_owner",
        display_name: "Settings Owner"
      })

    member =
      user_fixture(%{
        email: "settings-member@example.com",
        username: "settings_member",
        display_name: "Settings Member"
      })

    token = Accounts.generate_user_session_token(owner)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:settings-owner")

    {conn, owner, member}
  end

  defp log_in_member_with_owner(conn) do
    owner =
      owner_fixture(%{
        email: "settings-owner2@example.com",
        username: "settings_owner2",
        display_name: "Settings Owner2"
      })

    member =
      user_fixture(%{
        email: "settings-member2@example.com",
        username: "settings_member2",
        display_name: "Settings Member2"
      })

    token = Accounts.generate_user_session_token(member)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:settings-member")

    {conn, owner, member}
  end

  defp current_user_from_conn(conn) do
    token = Plug.Conn.get_session(conn, :user_token)
    Accounts.get_user_by_session_token(token)
  end
end
