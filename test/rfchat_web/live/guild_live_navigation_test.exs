defmodule RfchatWeb.GuildLiveNavigationTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures
  import RfchatWeb.GuildLiveFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Repo

  test "renders guild shell with seeded channels and welcome message", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)

    {:ok, _view, html} = live_hydrated(conn, ~p"/")

    assert html =~ "RFChat"
    assert html =~ "General"
    assert html =~ "Welcome to RFChat"
  end

  test "connected mount returns before the channel list loads and hydration then fills it", %{
    conn: conn
  } do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)

    {:ok, _view, mounted_html} = live(conn, ~p"/")
    mounted = LazyHTML.from_fragment(mounted_html)

    assert LazyHTML.query(mounted, "#guild-shell[data-hydrated=false]") |> Enum.count() == 1
    assert LazyHTML.query(mounted, "#channel-link-general") |> Enum.count() == 0

    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    assert has_element?(view, "#guild-shell[data-hydrated=true]")
    assert has_element?(view, "#channel-link-general")
  end

  test "switches channels by patching the channel slug", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

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
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

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

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=#{hidden_channel.slug}")

    assert_patch(view, ~p"/?channel=general")
    assert has_element?(view, "#flash-error")
  end

  test "shows unread badge for inactive channel messages and clears it on visit", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    sender = user_fixture(%{email: "badge-sender@example.com", username: "badge_sender"})

    engineering = Chat.get_channel_by_slug!("engineering")

    {:ok, _message} =
      Chat.create_message(scope_for(sender), engineering.id, %{body: "new engineering update"})

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
    {:ok, view, _html} = live_hydrated(conn, ~p"/")
    current_user = Rfchat.Accounts.get_user_by_email("guildlive-default@example.com")
    assert current_user

    sender =
      user_fixture(%{
        email: "mention-badge-sender@example.com",
        username: "mention_badge_sender"
      })

    engineering = Chat.get_channel_by_slug!("engineering")

    {:ok, message} =
      Chat.create_message(scope_for(sender), engineering.id, %{
        body: "hello @#{current_user.username}",
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

  test "receives inactive channel mention from another hydrated user", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    receiver_conn = log_in_member_user(conn, "mention_receiver")
    {:ok, receiver_view, _html} = live_hydrated(receiver_conn, ~p"/")

    engineering = Chat.get_channel_by_slug!("engineering")
    denied_sender = user_fixture(%{username: "mention_denied_sender"})

    assert {:error, changeset} =
             Chat.create_message(scope_for(denied_sender), engineering.id, %{body: "@here"})

    assert Enum.any?(changeset.errors, fn
             {:body, {message, _opts}} ->
               message == "You do not have permission to mention that role."

             _error ->
               false
           end)

    refute has_element?(receiver_view, "#channel-mention-engineering")

    allowed_sender = owner_fixture(%{username: "mention_allowed_sender"})

    {:ok, _message} =
      Chat.create_message(scope_for(allowed_sender), engineering.id, %{body: "@here"})

    _ = :sys.get_state(receiver_view.pid)

    expected_body = "@here"

    assert has_element?(receiver_view, "#channel-mention-engineering")

    assert_push_event(receiver_view, "notify:mention", %{
      author_name: "Test User",
      body: ^expected_body,
      channel_name: "Engineering"
    })
  end

  test "counts an inactive channel message once after channel and thread navigation", %{
    conn: conn
  } do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    general = Chat.get_channel_by_slug!("general")
    author = current_user_from_conn(conn)
    starter = message_fixture(general, author, %{body: "navigation thread starter"})
    _thread = thread_fixture(general, starter, author)
    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general")

    view |> element("#channel-link-engineering") |> render_click()
    assert_patch(view, ~p"/?channel=engineering")
    view |> element("#channel-link-general") |> render_click()
    assert_patch(view, ~p"/?channel=general")
    view |> element("#open-thread-#{starter.id}") |> render_click()
    assert has_element?(view, "#thread-panel-#{starter.id}")
    view |> element("#close-thread-#{starter.id}") |> render_click()
    refute has_element?(view, "#thread-panel-#{starter.id}")

    sender = user_fixture(%{email: "nav-once-sender@example.com", username: "nav_once_sender"})
    engineering = Chat.get_channel_by_slug!("engineering")

    {:ok, _message} =
      Chat.create_message(scope_for(sender), engineering.id, %{body: "counted once"})

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#channel-unread-engineering", ~r/^\s*1\s*$/)
  end

  test "shows unread badge for a channel that becomes visible while connected", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    channel = channel_fixture(%{name: "Late Reveal", slug: unique_slug(), position: 20})

    overwrite =
      channel_permission_overwrite_fixture(channel, %{
        role_id: Chat.default_role().id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")
    refute has_element?(view, "#channel-link-#{channel.slug}")

    Repo.delete!(overwrite)
    {:ok, channel} = Chat.update_channel(channel, %{topic: "now visible"})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#channel-link-#{channel.slug}")

    sender = user_fixture(%{email: "reveal-sender@example.com", username: "reveal_sender"})
    {:ok, _message} = Chat.create_message(scope_for(sender), channel.id, %{body: "after reveal"})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#channel-unread-#{channel.slug}", ~r/^\s*1\s*$/)
  end

  test "lists a channel created while connected and shows its unread badge", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    channel = channel_fixture(%{name: "Fresh Channel", slug: unique_slug(), position: 20})
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#channel-link-#{channel.slug}")

    sender = user_fixture(%{email: "fresh-sender@example.com", username: "fresh_sender"})
    {:ok, _message} = Chat.create_message(scope_for(sender), channel.id, %{body: "first post"})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#channel-unread-#{channel.slug}", ~r/^\s*1\s*$/)
  end

  test "supports opening and closing the mobile channel drawer", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    assert has_element?(view, "#mobile-channel-drawer.-translate-x-full")

    view |> element("#open-mobile-sidebar") |> render_click()
    assert has_element?(view, "#mobile-channel-drawer.translate-x-0")

    view |> element("#mobile-sidebar-overlay") |> render_click()
    assert has_element?(view, "#mobile-channel-drawer.-translate-x-full")
  end

  test "supports opening and closing the mobile members drawer", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    assert has_element?(view, "#mobile-members-drawer.translate-x-full")

    view |> element("#open-mobile-members") |> render_click()
    assert has_element?(view, "#mobile-members-drawer.translate-x-0")

    view |> element("#mobile-members-overlay") |> render_click()
    assert has_element?(view, "#mobile-members-drawer.translate-x-full")
  end

  test "settings trigger opens consolidated settings panel", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    assert has_element?(view, "#open-settings-link")

    assert {:error, {:live_redirect, %{to: "/settings"}}} =
             view |> element("#open-settings-link") |> render_click()

    {:ok, settings_view, _html} = live(conn, ~p"/settings")
    assert has_element?(settings_view, "#settings-panel-title")
  end
end
