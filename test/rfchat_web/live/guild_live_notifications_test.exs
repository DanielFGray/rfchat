defmodule RfchatWeb.GuildLiveNotificationsTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures
  import RfchatWeb.GuildLiveFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat

  test "pushes a browser mention notification event for inactive channel mentions", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")
    current_user = Rfchat.Accounts.get_user_by_email("guildlive-default@example.com")
    assert current_user

    sender =
      user_fixture(%{
        email: "mention-notify-sender@example.com",
        username: "mention_notify_sender",
        display_name: "Mention Notify Sender"
      })

    engineering = Chat.get_channel_by_slug!("engineering")
    channel_id = engineering.id

    {:ok, _message} =
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

    assert_push_event(view, "notify:mention", %{
      author_name: "Mention Notify Sender",
      channel_id: ^channel_id,
      channel_name: "Engineering",
      body: "hello @guildlive_user_default"
    })
  end

  test "enables desktop mention alerts and requests browser permission", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/settings?tab=notifications")

    assert has_element?(view, "#disable-desktop-mentions")
    view |> element("#disable-desktop-mentions") |> render_click()
    assert has_element?(view, "#enable-desktop-mentions")
    view |> element("#enable-desktop-mentions") |> render_click()

    assert_push_event(view, "notifications:request-permission", %{})
    assert has_element?(view, "#disable-desktop-mentions")
  end

  test "suppresses browser mention event when desktop mention alerts are disabled", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")
    current_user = Rfchat.Accounts.get_user_by_email("guildlive-default@example.com")
    assert current_user

    {:ok, _setting} =
      Chat.update_user_notification_setting(current_user, %{
        desktop_enabled: false,
        notify_on_mentions: true
      })

    sender =
      user_fixture(%{
        email: "mention-notify-disabled@example.com",
        username: "mention_notify_disabled",
        display_name: "Mention Disabled Sender"
      })

    engineering = Chat.get_channel_by_slug!("engineering")

    {:ok, _message} =
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

    refute_push_event(view, "notify:mention", %{})
  end

  test "renders member sidebar with owner and activity indicators", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#member-sidebar")
    assert has_element?(view, "#member-sidebar", "Guildlive User default")
    assert has_element?(view, "#member-sidebar", "owner")
  end
end
