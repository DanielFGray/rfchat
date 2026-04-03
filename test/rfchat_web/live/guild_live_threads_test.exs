defmodule RfchatWeb.GuildLiveThreadsTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures
  import RfchatWeb.GuildLiveFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat

  test "creates and replies inside an inline thread", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#message-form", %{message: %{body: "starter for inline thread"}})
    |> render_submit()

    starter =
      Chat.get_channel_by_slug!("general").id
      |> Chat.list_messages()
      |> Enum.find(&(&1.body == "starter for inline thread"))

    view |> element("#create-thread-#{starter.id}") |> render_click()

    thread = Chat.get_thread_for_starter_message(starter.id)
    assert thread
    _ = :sys.get_state(view.pid)

    view |> element("#open-thread-#{starter.id}") |> render_click()

    assert has_element?(view, "#thread-panel-#{starter.id}")
    assert has_element?(view, "#thread-message-form")

    view
    |> form("#thread-message-form", %{message: %{body: "thread reply body"}})
    |> render_submit()

    assert has_element?(view, "#thread-panel-#{starter.id}", "thread reply body")
    assert has_element?(view, "#thread-summary-#{starter.id}", "1 replies")
  end

  test "opens focused thread view from params", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    general = Chat.get_channel_by_slug!("general")
    author = current_user_from_conn(conn)
    starter = message_fixture(general, author, %{body: "focused thread starter"})
    thread = thread_fixture(general, starter, author)
    _reply = message_fixture(thread, author, %{body: "focused thread reply"})

    {:ok, view, _html} = live(conn, ~p"/?channel=general&thread=#{thread.id}")

    assert has_element?(view, "#thread-panel-#{starter.id}")
    assert has_element?(view, "#thread-panel-#{starter.id}", "focused thread reply")
    assert has_element?(view, "#thread-view-focus-#{starter.id}", "Focused")
  end

  test "supports replying to a thread message", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    general = Chat.get_channel_by_slug!("general")
    author = current_user_from_conn(conn)
    starter = message_fixture(general, author, %{body: "replyable thread starter"})
    thread = thread_fixture(general, starter, author)
    reply = message_fixture(thread, author, %{body: "first thread reply"})

    _ = :sys.get_state(view.pid)

    view |> element("#channel-link-general") |> render_click()
    _ = :sys.get_state(view.pid)

    view |> element("#open-thread-#{starter.id}") |> render_click()
    view |> element("#reply-in-thread-#{reply.id}") |> render_click()

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#thread-replying-to-banner")

    view
    |> form("#thread-message-form", %{message: %{body: "nested thread reply"}})
    |> render_submit()

    assert has_element?(view, "#thread-panel-#{starter.id}", "nested thread reply")
    assert render(view) =~ "Replying to"
  end
end
