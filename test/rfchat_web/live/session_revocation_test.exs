defmodule RfchatWeb.SessionRevocationTest do
  # A member's open LiveViews keep what they loaded at mount. Each test changes the member's
  # standing from another process, then drives the member's next event and expects the context
  # to refuse it from the database.
  use RfchatWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures
  import RfchatWeb.GuildLiveFixtures

  alias Rfchat.Accounts
  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.MemberRole
  alias Rfchat.Chat.UserSession
  alias Rfchat.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    member = user_fixture()
    {:ok, owner: owner, member: member, general: channel_by_slug!("general")}
  end

  describe "send after a moderation action" do
    test "a timed-out member's next send is refused and the view survives", ctx do
      {:ok, view, _html} = connect_guild(ctx.conn, ctx.member)

      assert {:ok, _subject, _case} =
               Chat.timeout_member(scope_for(ctx.owner), ctx.member.id, 10)

      send_body(view, "after timeout")

      assert render(view) =~ "permission"
      assert sent_messages(ctx.general.id) == []
    end

    test "a kicked member's next send is refused and the view survives", ctx do
      {:ok, view, _html} = connect_guild(ctx.conn, ctx.member)

      assert {:ok, _subject, _case} = Chat.kick_member(scope_for(ctx.owner), ctx.member.id)

      send_body(view, "after kick")

      assert render(view) =~ "permission"
      assert sent_messages(ctx.general.id) == []

      assert {:error, :not_found} =
               Chat.create_message(scope_for(ctx.member), ctx.general.id, %{"body" => "x"})
    end

    test "a banned member's next send is refused and the view survives", ctx do
      {:ok, view, _html} = connect_guild(ctx.conn, ctx.member)

      assert {:ok, _subject, _case} = Chat.ban_member(scope_for(ctx.owner), ctx.member.id, "spam")

      send_body(view, "after ban")

      assert render(view) =~ "permission"
      assert sent_messages(ctx.general.id) == []
    end
  end

  describe "management after a loss of authority" do
    test "a demoted owner's next channel save is refused", ctx do
      second_owner = owner_fixture()
      {:ok, view} = connect_channel_manager(ctx.conn, second_owner)

      assert {:ok, _membership} =
               Accounts.demote_from_owner(scope_for(ctx.owner), second_owner.id)

      create_channel_through(view, "demoted-owner-channel")

      assert view |> render() =~ "cannot be changed"
      refute Repo.get_by(Chat.Channel, slug: "demoted-owner-channel")
    end

    test "a member whose role row was removed cannot save a channel", ctx do
      manager = channel_manager_fixture()
      {:ok, view} = connect_channel_manager(ctx.conn, manager)

      Repo.delete_all(from(member_role in MemberRole, where: member_role.user_id == ^manager.id))

      create_channel_through(view, "revoked-role-channel")

      assert render(view) =~ "cannot be changed"
      refute Repo.get_by(Chat.Channel, slug: "revoked-role-channel")
    end
  end

  describe "emoji upload" do
    test "a member without manage_emojis_and_stickers is refused before the upload is read",
         ctx do
      upload = %{path: "/nonexistent", client_name: "a.png", client_type: "image/png"}

      assert {:error, :forbidden} =
               Chat.create_custom_emoji_from_upload(%{"name" => "party"}, ctx.member, upload)
    end
  end

  describe "sessions" do
    test "a kick deletes the subject's sessions and disconnects their sockets", ctx do
      token = Accounts.generate_user_session_token(ctx.member)
      other = Accounts.generate_user_session_token(ctx.member)
      bystander = Accounts.generate_user_session_token(ctx.owner)

      for t <- [token, other], do: RfchatWeb.Endpoint.subscribe(Accounts.live_socket_id(t))
      RfchatWeb.Endpoint.subscribe(Accounts.live_socket_id(bystander))

      assert {:ok, _subject, _case} = Chat.kick_member(scope_for(ctx.owner), ctx.member.id)

      for t <- [token, other] do
        topic = Accounts.live_socket_id(t)
        assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      end

      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 50

      assert Repo.aggregate(from(s in UserSession, where: s.user_id == ^ctx.member.id), :count) ==
               0

      assert Repo.aggregate(from(s in UserSession, where: s.user_id == ^ctx.owner.id), :count) ==
               1

      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "a ban deletes the subject's sessions and disconnects their sockets", ctx do
      token = Accounts.generate_user_session_token(ctx.member)
      topic = Accounts.live_socket_id(token)
      RfchatWeb.Endpoint.subscribe(topic)

      assert {:ok, _subject, _case} = Chat.ban_member(scope_for(ctx.owner), ctx.member.id, "spam")

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "a timeout keeps the subject's sessions", ctx do
      token = Accounts.generate_user_session_token(ctx.member)
      RfchatWeb.Endpoint.subscribe(Accounts.live_socket_id(token))

      assert {:ok, _subject, _case} = Chat.timeout_member(scope_for(ctx.owner), ctx.member.id, 5)

      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 50
      assert Accounts.get_user_by_session_token(token)
    end

    test "log in stores a socket id the server can derive, and log out disconnects it", ctx do
      conn =
        post(ctx.conn, ~p"/login", %{
          user: %{email: ctx.member.email, password: "supersecurepass"}
        })

      token = get_session(conn, :user_token)

      assert get_session(conn, :live_socket_id) == Accounts.live_socket_id(token)

      RfchatWeb.Endpoint.subscribe(Accounts.live_socket_id(token))
      conn = conn |> recycle() |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert Accounts.get_user_by_session_token(token) == nil
    end
  end

  describe "logging in after removal" do
    test "a kicked member reaches only the removed page", ctx do
      assert {:ok, _subject, _case} = Chat.kick_member(scope_for(ctx.owner), ctx.member.id)

      conn = login(ctx.conn, ctx.member)

      for path <- [~p"/", ~p"/settings"] do
        assert redirected_to(get(conn, path)) == ~p"/banned"
      end

      assert {:ok, _view, _html} = live(conn, ~p"/banned")
    end

    test "a banned member reaches only the banned page", ctx do
      assert {:ok, _subject, _case} = Chat.ban_member(scope_for(ctx.owner), ctx.member.id, "spam")

      conn = login(ctx.conn, ctx.member)

      for path <- [~p"/", ~p"/settings"] do
        assert redirected_to(get(conn, path)) == ~p"/banned"
      end

      assert {:ok, _view, _html} = live(conn, ~p"/banned")
    end
  end

  defp login(conn, user) do
    conn =
      post(conn, ~p"/login", %{user: %{email: user.email, password: "supersecurepass"}})

    recycle(conn)
  end

  defp connect_guild(conn, user) do
    conn |> session_for(user) |> live_hydrated(~p"/")
  end

  defp connect_channel_manager(conn, user) do
    {:ok, view, _html} = conn |> session_for(user) |> live(~p"/settings?tab=server")
    view |> element("#open-channel-manager") |> render_click()
    {:ok, view}
  end

  defp session_for(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Accounts.generate_user_session_token(user))
  end

  # The seeded welcome message is a system message; only a member's own sends count here.
  defp sent_messages(channel_id),
    do: channel_id |> messages_in() |> Enum.filter(&(&1.kind != :system))

  defp send_body(view, body) do
    view |> form("#message-form", %{message: %{body: body}}) |> render_submit()
  end

  defp create_channel_through(view, slug) do
    view |> form("#channel-form", %{channel: %{name: slug, slug: slug}}) |> render_submit()
  end
end
