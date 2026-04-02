defmodule RfchatWeb.GuildLiveTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.MessageRoleMention
  alias Rfchat.Chat.MessageUserMention
  alias Rfchat.Chat.PermissionBits
  import Rfchat.ChatFixtures

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
             }}} =
             live(conn, ~p"/?channel=#{hidden_channel.slug}")
  end

  test "posts a message into the active channel", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#message-form", %{message: %{body: "hello from liveview"}})
      |> render_submit()

    assert html =~ "hello from liveview"
    assert render(view) =~ "2 messages"
    refute render(view) =~ "value=\"hello from liveview\""
  end

  test "stores composer metadata with mention and slash command entities", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    metadata = %{
      "composer" => "tiptap",
      "entities" => [
        %{"type" => "mention", "id" => "user-1", "label" => "member_default"},
        %{"type" => "slash_command", "id" => "shrug", "label" => "shrug"}
      ],
      "document" => %{"type" => "doc", "content" => []}
    }

    view
    |> form("#message-form", %{
      message: %{
        body: "hey @member_default /shrug",
        metadata: Jason.encode!(metadata)
      }
    })
    |> render_submit()

    message =
      Chat.get_channel_by_slug!("general").id
      |> Chat.list_messages()
      |> Enum.find(&(&1.body == "hey @member_default /shrug"))

    assert %{"composer" => "tiptap", "entities" => entities} = message.metadata
    assert Enum.any?(entities, &(&1["type"] == "mention"))
    assert Enum.any?(entities, &(&1["type"] == "slash_command"))
  end

  test "persists user and role mention records from composer submissions", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    mentioned_user = user_fixture(%{email: "lv-mentioned@example.com", username: "lv_mentioned"})
    role = role_fixture(%{name: "@design", mentionable: true})

    metadata = %{
      "composer" => "tiptap",
      "entities" => [
        %{"type" => "mention", "id" => mentioned_user.id, "label" => mentioned_user.username},
        %{
          "type" => "mention",
          "id" => role.id,
          "label" => String.trim_leading(role.name, "@")
        }
      ],
      "document" => %{"type" => "doc", "content" => []}
    }

    view
    |> form("#message-form", %{
      message: %{
        body: "hey @lv_mentioned and @design",
        metadata: Jason.encode!(metadata)
      }
    })
    |> render_submit()

    message =
      Chat.get_channel_by_slug!("general").id
      |> Chat.list_messages()
      |> Enum.find(&(&1.body == "hey @lv_mentioned and @design"))

    assert Rfchat.Repo.get_by(MessageUserMention,
             message_id: message.id,
             mentioned_user_id: mentioned_user.id
           )

    assert Rfchat.Repo.get_by(MessageRoleMention,
             message_id: message.id,
             mentioned_role_id: role.id
           )
  end

  test "fans out new messages to other connected guild sessions", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    sender_conn = log_in_member_user(conn, "sender")
    receiver_conn = log_in_member_user(recycle(conn), "receiver")

    {:ok, sender_view, _html} = live(sender_conn, ~p"/")
    {:ok, receiver_view, _html} = live(receiver_conn, ~p"/")

    sender_view
    |> form("#message-form", %{message: %{body: "hello from another session"}})
    |> render_submit()

    _ = :sys.get_state(receiver_view.pid)

    assert has_element?(receiver_view, "#message-list", "hello from another session")
  end

  test "shows unread badge for inactive channel messages and clears it on visit", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    sender =
      user_fixture(%{
        email: "badge-sender@example.com",
        username: "badge_sender"
      })

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
    {:ok, view, _html} = live(conn, ~p"/")

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

  test "supports replying to a message", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    original =
      Chat.list_messages(Chat.get_channel_by_slug!("general").id)
      |> List.first()

    view |> element("#reply-message-#{original.id}") |> render_click()

    assert has_element?(view, "#replying-to-banner")

    view
    |> form("#message-form", %{message: %{body: "reply message body"}})
    |> render_submit()

    assert has_element?(view, "#message-list", "reply message body")
    assert render(view) =~ "Replying to"
  end

  test "supports editing an authored message", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#message-form", %{message: %{body: "editable body"}})
    |> render_submit()

    message =
      Chat.get_channel_by_slug!("general").id
      |> Chat.list_messages()
      |> Enum.find(&(&1.body == "editable body"))

    view |> element("#edit-message-#{message.id}") |> render_click()
    assert has_element?(view, "#edit-message-form-#{message.id}")

    view
    |> form("#edit-message-form-#{message.id}", %{message: %{id: message.id, body: "edited body"}})
    |> render_submit()

    assert has_element?(view, "#message-list", "edited body")
    assert render(view) =~ "(edited)"
  end

  test "supports deleting an authored message", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#message-form", %{message: %{body: "delete me"}})
    |> render_submit()

    message =
      Chat.get_channel_by_slug!("general").id
      |> Chat.list_messages()
      |> Enum.find(&(&1.body == "delete me"))

    view |> element("#delete-message-#{message.id}") |> render_click()

    assert has_element?(view, "#message-list", "[message deleted]")
    assert render(view) =~ "deleted"
  end

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

    {:ok, view, _html} = live(conn, ~p"/")
    message = Chat.list_messages(Chat.get_channel_by_slug!("general").id) |> List.first()
    quick_reaction_id = Base.url_encode64("👍", padding: false)

    refute has_element?(view, "#reaction-#{message.id}-#{quick_reaction_id}")

    view |> element("#open-reaction-picker-#{message.id}") |> render_click()

    assert has_element?(view, "#reaction-picker-default-#{message.id}-#{quick_reaction_id}")
    assert render(view) =~ "reaction-picker-search-#{message.id}"
    assert render(view) =~ "data-reaction-picker-defaults"
    assert has_element?(view, "#reaction-picker-custom-#{message.id}-#{emoji.id}")
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

  test "moderators can delete other users messages", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    moderator_role =
      role_fixture(%{
        name: "Mod Delete",
        permissions: PermissionBits.combine([:manage_messages])
      })

    moderator =
      user_fixture(%{
        email: "guildlive-moderator@example.com",
        username: "guildlive_moderator",
        display_name: "Guildlive Moderator"
      })

    _member_role = member_role_fixture(moderator, moderator_role)

    author =
      user_fixture(%{
        email: "guildlive-author@example.com",
        username: "guildlive_author",
        display_name: "Guildlive Author"
      })

    general = Chat.get_channel_by_slug!("general")
    message = message_fixture(general, author, %{body: "moderate me"})

    token = Rfchat.Accounts.generate_user_session_token(moderator)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:moderator")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#delete-message-#{message.id}")

    view |> element("#delete-message-#{message.id}") |> render_click()

    assert has_element?(view, "#message-list", "[message deleted]")
  end

  test "shows composer guidance when mention_everyone is unavailable", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#message-form", "@everyone and locked roles need extra permission")
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

  test "owners can open channel manager and create a category plus child channel", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_owner_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

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

    assert has_element?(view, "#channel-link-roadmap")
    assert has_element?(view, "#manager-channel-section-product", "Roadmap")
  end

  test "owners can edit and reorder channels from the manager", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_owner_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#open-channel-manager") |> render_click()
    view |> element("#edit-channel-engineering") |> render_click()

    assert has_element?(view, "#channel-form")

    view
    |> form("#channel-form", %{
      channel: %{name: "Platform", slug: "platform", topic: "Platform work"}
    })
    |> render_submit()

    assert has_element?(view, "#channel-link-platform")
    refute has_element?(view, "#channel-link-engineering")

    view |> element("#move-channel-down-general") |> render_click()

    general = Chat.get_channel_by_slug!("general")
    platform = Chat.get_channel_by_slug!("platform")

    assert general.position > platform.position
  end

  test "non-managers do not see channel management controls", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#open-channel-manager")
    refute has_element?(view, "#channel-manager-panel")
  end

  test "administrator role surfaces channel management controls", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    _owner =
      user_fixture(%{email: "guildlive-owner-admin@example.com", username: "owner_admin_ui"})

    admin_role =
      role_fixture(%{
        name: "Admin UI",
        permissions: PermissionBits.combine([:administrator])
      })

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

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#open-channel-manager")
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

    {:ok, view, _html} = live(conn, ~p"/")

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

  defp log_in_member_user(conn, suffix \\ "default") do
    _owner =
      user_fixture(%{
        email: "owner-guildlive-#{suffix}@example.com",
        username: "owner_#{suffix}",
        display_name: "Owner Guildlive User #{suffix}"
      })

    user =
      user_fixture(%{
        email: "guildlive-#{suffix}@example.com",
        username: "member_#{suffix}",
        display_name: "Guildlive User #{suffix}"
      })

    token = Rfchat.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:test")
  end

  defp log_in_owner_user(conn) do
    user =
      user_fixture(%{
        email: "guildlive-owner@example.com",
        username: "guildlive_owner",
        display_name: "Guildlive Owner"
      })

    token = Rfchat.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:owner")
  end

  defp current_user_from_conn(conn) do
    token = Plug.Conn.get_session(conn, :user_token)
    Rfchat.Accounts.get_user_by_session_token(token)
  end

  defp category_id(slug), do: Chat.get_channel_by_slug!(slug).id
end
