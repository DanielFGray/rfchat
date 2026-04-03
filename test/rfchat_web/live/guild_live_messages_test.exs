defmodule RfchatWeb.GuildLiveMessagesTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures
  import RfchatWeb.GuildLiveFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.MessageRoleMention
  alias Rfchat.Chat.MessageUserMention
  alias Rfchat.Chat.PermissionBits

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
      message: %{body: "hey @member_default /shrug", metadata: Jason.encode!(metadata)}
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
        %{"type" => "mention", "id" => role.id, "label" => String.trim_leading(role.name, "@")}
      ],
      "document" => %{"type" => "doc", "content" => []}
    }

    view
    |> form("#message-form", %{
      message: %{body: "hey @lv_mentioned and @design", metadata: Jason.encode!(metadata)}
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

  test "supports replying to a message", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    original = Chat.list_messages(Chat.get_channel_by_slug!("general").id) |> List.first()

    view |> element("#quick-reply-message-#{original.id}") |> render_click()

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

    view |> form("#message-form", %{message: %{body: "editable body"}}) |> render_submit()

    message =
      Chat.get_channel_by_slug!("general").id
      |> Chat.list_messages()
      |> Enum.find(&(&1.body == "editable body"))

    view |> element("#open-message-actions-#{message.id}") |> render_click()
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

    view |> form("#message-form", %{message: %{body: "delete me"}}) |> render_submit()

    message =
      Chat.get_channel_by_slug!("general").id
      |> Chat.list_messages()
      |> Enum.find(&(&1.body == "delete me"))

    view |> element("#open-message-actions-#{message.id}") |> render_click()
    view |> element("#prompt-delete-message-#{message.id}") |> render_click()
    view |> element("#delete-message-#{message.id}") |> render_click()

    assert has_element?(view, "#message-list", "[message deleted]")
    assert render(view) =~ "deleted"
  end

  test "moderators can delete other users messages", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    moderator_role =
      role_fixture(%{name: "Mod Delete", permissions: PermissionBits.combine([:manage_messages])})

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

    view |> element("#open-message-actions-#{message.id}") |> render_click()
    assert has_element?(view, "#prompt-delete-message-#{message.id}")

    view |> element("#prompt-delete-message-#{message.id}") |> render_click()
    view |> element("#delete-message-#{message.id}") |> render_click()

    assert has_element?(view, "#message-list", "[message deleted]")
  end

  test "shows composer guidance when mention_everyone is unavailable", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#message-form", "@everyone and locked roles need extra permission")
    refute has_element?(view, "#message-form", "mentions enabled")

    refute has_element?(
             view,
             "#message-form",
             "Markdown, mentions, slash commands, code blocks, and rich links"
           )

    assert has_element?(view, "#rich-composer-toolbar [aria-label='Bold']")
  end
end
