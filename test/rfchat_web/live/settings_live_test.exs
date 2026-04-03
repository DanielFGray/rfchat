defmodule RfchatWeb.SettingsLiveTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rfchat.Accounts
  alias Rfchat.Bootstrap
  import Rfchat.ChatFixtures

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
      member_with_membership = Accounts.get_user_with_membership!(member.id)
      owner_user = current_user_from_conn(conn)
      {:ok, _} = Accounts.promote_to_owner(owner_user, member_with_membership)

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

  defp log_in_owner_with_member(conn) do
    owner =
      user_fixture(%{
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
      user_fixture(%{
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
