defmodule TavernWeb.GuildLiveThreadsTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.GuildLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat

  test "creates and replies inside an inline thread", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    view
    |> form("#message-form", %{message: %{body: "starter for inline thread"}})
    |> render_submit()

    starter =
      channel_by_slug!("general").id
      |> messages_in()
      |> Enum.find(&(&1.body == "starter for inline thread"))

    view |> element("#create-thread-#{starter.id}") |> render_click()

    thread =
      Chat.get_thread_for_starter_message(scope_for(current_user_from_conn(conn)), starter.id)

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
    general = channel_by_slug!("general")
    author = current_user_from_conn(conn)
    starter = message_fixture(general, author, %{body: "focused thread starter"})
    thread = thread_fixture(general, starter, author)
    _reply = message_fixture(thread, author, %{body: "focused thread reply"})

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general&thread=#{thread.id}")

    assert has_element?(view, "#thread-panel-#{starter.id}")
    assert has_element?(view, "#thread-panel-#{starter.id}", "focused thread reply")
    assert has_element?(view, "#thread-view-focus-#{starter.id}", "Focused")
  end

  test "supports replying to a thread message", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    general = channel_by_slug!("general")
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

  test "renders the thread typing indicator shell for the active thread", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn, "author")

    general = channel_by_slug!("general")
    author = current_user_from_conn(conn)
    starter = message_fixture(general, author, %{body: "thread typing starter"})
    thread = thread_fixture(general, starter, author)

    typer = author

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general&thread=#{thread.id}")

    :ok = Chat.announce_typing(scope_for(typer), thread.id)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#thread-typing-indicator-#{starter.id}")

    :ok = Chat.clear_typing(scope_for(typer), thread.id)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#thread-typing-indicator-#{starter.id}")
  end

  test "slowmode refuses a second send with a flash and the seconds left", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    general = channel_by_slug!("general")
    general |> Ecto.Changeset.change(slowmode_seconds: 60) |> Tavern.Repo.update!()
    {:ok, view, _html} = live_hydrated(conn, ~p"/")

    view |> form("#message-form", %{message: %{body: "first"}}) |> render_submit()
    refute has_element?(view, "#flash-error")

    view |> form("#message-form", %{message: %{body: "second"}}) |> render_submit()

    assert has_element?(view, "#flash-error", "Slowmode")

    assert [%{body: "first"}] =
             Enum.filter(messages_in(general.id), &(&1.body in ["first", "second"]))
  end

  test "a thread creator archives it, and a lock takes the controls away",
       %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    general = channel_by_slug!("general")
    author = current_user_from_conn(conn)
    starter = message_fixture(general, author, %{body: "controls starter"})
    thread = thread_fixture(general, starter, author)

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general&thread=#{thread.id}")

    assert has_element?(view, "#toggle-archive-thread-#{starter.id}", "Archive")
    refute has_element?(view, "#toggle-lock-thread-#{starter.id}")

    view |> element("#toggle-archive-thread-#{starter.id}") |> render_click()
    assert has_element?(view, "#thread-archived-badge-#{starter.id}")
    assert has_element?(view, "#toggle-archive-thread-#{starter.id}", "Unarchive")

    moderator = Tavern.ChatFixtures.user_fixture()

    role =
      role_fixture(%{
        permissions: Tavern.Chat.PermissionBits.combine([:view_channel, :manage_messages])
      })

    member_role_fixture(moderator, role)
    {:ok, _} = Chat.lock_thread(scope_for(moderator), thread.id)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#thread-locked-badge-#{starter.id}")
    refute has_element?(view, "#toggle-archive-thread-#{starter.id}")
  end

  test "a manager locks and unlocks a thread from its header", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    conn = log_in_member_user(conn)
    general = channel_by_slug!("general")
    me = current_user_from_conn(conn)

    role =
      role_fixture(%{
        permissions:
          Tavern.Chat.PermissionBits.combine([
            :view_channel,
            :send_messages,
            :manage_messages
          ])
      })

    member_role_fixture(me, role)
    starter = message_fixture(general, me, %{body: "lockable starter"})
    thread = thread_fixture(general, starter, me)

    {:ok, view, _html} = live_hydrated(conn, ~p"/?channel=general&thread=#{thread.id}")

    view |> element("#toggle-lock-thread-#{starter.id}") |> render_click()
    assert has_element?(view, "#thread-locked-badge-#{starter.id}")
    assert has_element?(view, "#toggle-lock-thread-#{starter.id}", "Unlock")

    view |> element("#toggle-lock-thread-#{starter.id}") |> render_click()
    refute has_element?(view, "#thread-locked-badge-#{starter.id}")
  end
end
