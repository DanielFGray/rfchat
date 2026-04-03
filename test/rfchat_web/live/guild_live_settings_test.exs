defmodule RfchatWeb.GuildLiveSettingsTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures
  import RfchatWeb.GuildLiveFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.PermissionBits

  test "server settings can update server branding name", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_owner_user(conn)

    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    view
    |> form("#server-settings-form", %{server_settings: %{name: "Orbit HQ"}})
    |> render_submit()

    assert Chat.get_server_settings().name == "Orbit HQ"
    assert render(view) =~ "Orbit HQ"
  end

  test "owners can open server settings and create a category plus child channel", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_owner_user(conn)
    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    view |> element("#open-channel-manager") |> render_click()

    assert has_element?(view, "#channel-manager-panel.translate-x-0")

    view |> element("#new-category") |> render_click()

    view
    |> form("#channel-form", %{channel: %{name: "Product", slug: "product"}})
    |> render_submit()

    assert has_element?(view, "#manager-channel-section-product")

    view |> element("#new-text-channel") |> render_click()

    view
    |> form("#channel-form", %{
      channel: %{name: "Roadmap", slug: "roadmap", parent_channel_id: category_id("product")}
    })
    |> render_submit()

    assert has_element?(view, "#manage-channel-roadmap")
    assert has_element?(view, "#manager-channel-section-product", "Roadmap")
  end

  test "owners can edit and reorder channels from server settings", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_owner_user(conn)
    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    view |> element("#open-channel-manager") |> render_click()
    view |> element("#edit-channel-engineering") |> render_click()

    assert has_element?(view, "#channel-form")

    view
    |> form("#channel-form", %{
      channel: %{name: "Platform", slug: "platform", topic: "Platform work"}
    })
    |> render_submit()

    assert has_element?(view, "#manage-channel-platform")
    refute has_element?(view, "#manage-channel-engineering")

    view |> element("#move-channel-down-general") |> render_click()

    general = Chat.get_channel_by_slug!("general")
    platform = Chat.get_channel_by_slug!("platform")

    assert general.position > platform.position
  end

  test "non-managers do not see server management controls", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    refute has_element?(view, "#open-channel-manager")
    refute has_element?(view, "#channel-manager-panel")
  end

  test "administrator role surfaces server management controls", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    _owner =
      user_fixture(%{email: "guildlive-owner-admin@example.com", username: "owner_admin_ui"})

    admin_role =
      role_fixture(%{name: "Admin UI", permissions: PermissionBits.combine([:administrator])})

    user =
      user_fixture(%{
        email: "guildlive-admin-ui@example.com",
        username: "guildlive_admin_ui",
        display_name: "Guildlive Admin UI"
      })

    _member_role = member_role_fixture(user, admin_role)
    token = Rfchat.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:admin-ui")

    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    assert has_element?(view, "#open-channel-manager")
  end

  test "manage_bots permission surfaces bot registry in server settings", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    manager_role =
      role_fixture(%{name: "Bot Manager", permissions: PermissionBits.combine([:manage_bots])})

    user =
      user_fixture(%{
        email: "bot-manager@example.com",
        username: "bot_manager",
        display_name: "Bot Manager"
      })

    _member_role = member_role_fixture(user, manager_role)
    token = Rfchat.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:bot-manager")

    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    assert has_element?(view, "#bot-form")
    assert has_element?(view, "#bot-registry-list")
  end

  test "emoji managers can upload and delete custom emoji", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    manager_role =
      role_fixture(%{
        name: "Emoji Manager",
        permissions: PermissionBits.combine([:manage_emojis_and_stickers])
      })

    user =
      user_fixture(%{
        email: "emoji-manager@example.com",
        username: "emoji_manager",
        display_name: "Emoji Manager"
      })

    _member_role = member_role_fixture(user, manager_role)
    token = Rfchat.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:emoji-manager")

    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    view |> element("#open-emoji-manager") |> render_click()

    upload =
      file_input(view, "#emoji-form", :emoji_image, [
        %{
          last_modified: 1_711_000_000_000,
          name: "blob.png",
          content: "fake png bytes",
          type: "image/png"
        }
      ])

    render_upload(upload, "blob.png")

    view
    |> form("#emoji-form", %{emoji: %{name: "blobhype", shortcode: ":blobhype:"}})
    |> render_submit()

    assert has_element?(view, "#manage-emoji-#{List.last(Chat.list_custom_emojis()).id}")

    emoji = List.last(Chat.list_custom_emojis())
    view |> element("#delete-emoji-#{emoji.id}") |> render_click()
    refute Enum.any?(Chat.list_custom_emojis(), &(&1.id == emoji.id))
  end
end
