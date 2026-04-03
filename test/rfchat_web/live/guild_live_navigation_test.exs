defmodule RfchatWeb.GuildLiveNavigationTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures
  import RfchatWeb.GuildLiveFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.PermissionBits

  test "renders guild shell with seeded channels and welcome message", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "RFChat"
    assert html =~ "General"
    assert html =~ "Welcome to RFChat"
  end

  test "switches channels by patching the channel slug", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("#channel-link-engineering") |> render_click()
    assert_patch(view, ~p"/?channel=engineering")
    assert has_element?(view, "#message-form")
    assert render(view) =~ "technical chatter"
  end

  test "hides channels denied to the default role", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    hidden_channel = channel_fixture(%{name: "Ops", slug: unique_slug(), position: 20})

    channel_permission_overwrite_fixture(hidden_channel, %{
      role_id: Chat.default_role().id,
      deny_permissions: PermissionBits.combine([:view_channel, :send_messages])
    })

    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#channel-link-#{hidden_channel.slug}")
  end

  test "redirects away from forbidden channel slugs", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    hidden_channel = channel_fixture(%{name: "Ops", slug: unique_slug(), position: 20})

    channel_permission_overwrite_fixture(hidden_channel, %{
      role_id: Chat.default_role().id,
      deny_permissions: PermissionBits.combine([:view_channel, :send_messages])
    })

    conn = log_in_member_user(conn)

    assert {:error,
            {:live_redirect,
             %{
               to: "/?channel=general",
               flash: %{"error" => "You do not have access to that channel."}
             }}} = live(conn, ~p"/?channel=#{hidden_channel.slug}")
  end

  test "shows unread badge for inactive channel messages and clears it on visit", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    sender = user_fixture(%{email: "badge-sender@example.com", username: "badge_sender"})

    engineering = Chat.get_channel_by_slug!("engineering")
    {:ok, _message} = Chat.create_message(engineering, sender, %{body: "new engineering update"})

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#channel-unread-engineering", "1")

    view |> element("#channel-link-engineering") |> render_click()
    assert_patch(view, ~p"/?channel=engineering")
    refute has_element?(view, "#channel-unread-engineering")
  end

  test "shows unread mention indicator for inactive channel mentions and clears it on visit", %{
    conn: conn
  } do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")
    current_user = Rfchat.Accounts.get_user_by_email("guildlive-default@example.com")
    assert current_user

    sender =
      user_fixture(%{
        email: "mention-badge-sender@example.com",
        username: "mention_badge_sender"
      })

    engineering = Chat.get_channel_by_slug!("engineering")

    {:ok, message} =
      Chat.create_message(engineering, sender, %{
        body: "hello @guildlive_user_default",
        metadata: %{
          "entities" => [
            %{
              "type" => "mention",
              "id" => current_user.id,
              "label" => current_user.username
            }
          ]
        }
      })

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#channel-mention-engineering")

    view |> element("#channel-link-engineering") |> render_click()
    assert_patch(view, ~p"/?channel=engineering")
    refute has_element?(view, "#channel-mention-engineering")

    Chat.mark_channel_read(current_user, engineering, message)
  end

  test "supports opening and closing the mobile channel drawer", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#mobile-channel-drawer.-translate-x-full")

    view |> element("#open-mobile-sidebar") |> render_click()
    assert has_element?(view, "#mobile-channel-drawer.translate-x-0")

    view |> element("#mobile-sidebar-overlay") |> render_click()
    assert has_element?(view, "#mobile-channel-drawer.-translate-x-full")
  end

  test "supports opening and closing the mobile members drawer", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#mobile-members-drawer.translate-x-full")

    view |> element("#open-mobile-members") |> render_click()
    assert has_element?(view, "#mobile-members-drawer.translate-x-0")

    view |> element("#mobile-members-overlay") |> render_click()
    assert has_element?(view, "#mobile-members-drawer.translate-x-full")
  end

  test "settings trigger opens consolidated settings panel", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#open-settings-link")

    assert {:error, {:live_redirect, %{to: "/settings"}}} =
             view |> element("#open-settings-link") |> render_click()

    {:ok, settings_view, _html} = live(conn, ~p"/settings")
    assert has_element?(settings_view, "#settings-panel-title")
  end
end
