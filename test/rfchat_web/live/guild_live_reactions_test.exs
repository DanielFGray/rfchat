defmodule RfchatWeb.GuildLiveReactionsTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures
  import RfchatWeb.GuildLiveFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.PermissionBits

  test "supports toggling reactions with live aggregation", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    message = Chat.list_messages(Chat.get_channel_by_slug!("general").id) |> List.first()
    reaction_id = Base.url_encode64("👍", padding: false)

    view |> element("#open-reaction-picker-#{message.id}") |> render_click()
    view |> element("#reaction-picker-default-#{message.id}-#{reaction_id}") |> render_click()

    assert has_element?(view, "#reaction-#{message.id}-#{reaction_id}", "1")

    view |> element("#reaction-#{message.id}-#{reaction_id}") |> render_click()

    refute has_element?(view, "#reaction-#{message.id}-#{reaction_id}")
  end

  test "shows reaction disabled state when add reactions is denied", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    channel = Chat.get_channel_by_slug!("general")

    channel_permission_overwrite_fixture(channel, %{
      role_id: Chat.default_role().id,
      deny_permissions: PermissionBits.combine([:add_reactions])
    })

    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    message = Chat.list_messages(channel.id) |> List.first()
    assert has_element?(view, "#open-reaction-picker-#{message.id}[disabled]")

    assert has_element?(
             view,
             "#message-list",
             "Reactions are disabled for your permissions in this channel."
           )
  end

  test "picker shows default and custom reactions but no quick chips", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn, "picker_layout")
    user = current_user_from_conn(conn)
    emoji = emoji_fixture(user, %{name: "blobwow", shortcode: ":blobwow:"})
    server_settings_fixture(%{name: "Picker Layout"})

    {:ok, view, _html} = live(conn, ~p"/")
    message = Chat.list_messages(Chat.get_channel_by_slug!("general").id) |> List.first()
    quick_reaction_id = Base.url_encode64("👍", padding: false)

    refute has_element?(view, "#reaction-#{message.id}-#{quick_reaction_id}")

    view |> element("#open-reaction-picker-#{message.id}") |> render_click()

    assert has_element?(view, "#reaction-picker-default-#{message.id}-#{quick_reaction_id}")
    assert render(view) =~ "reaction-picker-search-#{message.id}"
    assert render(view) =~ "data-reaction-picker-defaults"
    assert has_element?(view, "#reaction-picker-custom-#{message.id}-#{emoji.id}")
    assert render(view) =~ "data-reaction-picker-custom"
  end

  test "opens reaction picker and toggles custom emoji reactions", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn, "custom_emoji")
    user = current_user_from_conn(conn)
    emoji = emoji_fixture(user, %{name: "blobparty", shortcode: ":blobparty:"})

    {:ok, view, _html} = live(conn, ~p"/")

    message = Chat.list_messages(Chat.get_channel_by_slug!("general").id) |> List.first()

    refute has_element?(view, "#reaction-picker-#{message.id}")

    view |> element("#open-reaction-picker-#{message.id}") |> render_click()

    assert has_element?(view, "#reaction-picker-#{message.id}")
    assert has_element?(view, "#reaction-picker-custom-#{message.id}-#{emoji.id}")

    view |> element("#reaction-picker-custom-#{message.id}-#{emoji.id}") |> render_click()

    assert has_element?(view, "#reaction-#{message.id}-custom-#{emoji.id}", "1")
    refute has_element?(view, "#reaction-picker-#{message.id}")
  end
end
