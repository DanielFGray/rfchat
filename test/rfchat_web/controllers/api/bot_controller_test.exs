defmodule RfchatWeb.API.BotControllerTest do
  use RfchatWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Rfchat.ChatFixtures

  alias Rfchat.Bots
  alias Rfchat.Chat
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Repo
  alias RfchatWeb.API.BotController
  alias RfchatWeb.TestStreamAdapter

  test "authenticated admins can create bots", %{conn: conn} do
    _owner = owner_fixture(%{email: "api-bot-owner@example.com", username: "api_bot_owner"})

    admin_role =
      role_fixture(%{
        name: "Bot Admin",
        permissions: PermissionBits.combine([:manage_bots])
      })

    user = user_fixture(%{email: "api-bot-admin@example.com", username: "api_bot_admin"})
    _member_role = member_role_fixture(user, admin_role)

    token = Rfchat.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:bot-admin")

    conn =
      post(conn, ~p"/api/v1/bots", %{
        bot: %{
          display_name: "API Helper",
          username: "api_helper",
          email: "api-helper@example.com",
          bio: "bot over api",
          role_ids: []
        }
      })

    assert %{"data" => %{"username" => "api_helper"}} = json_response(conn, 201)
  end

  test "bot token can send and list messages through API", _context do
    actor = owner_fixture(%{email: "bot-api-actor@example.com", username: "bot_api_actor"})

    role =
      role_fixture(%{
        name: "Bot Speaker",
        permissions: PermissionBits.combine([:view_channel, :send_messages])
      })

    channel = channel_fixture(%{name: "Bot Channel", slug: unique_slug()})
    bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})
    {:ok, %{token: bot_token}} = Bots.create_bot_token(bot_user, %{"label" => "api"}, actor)

    post_conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> post(~p"/api/v1/channels/#{channel.id}/messages", %{
        message: %{body: "hello from api bot"}
      })

    assert %{"data" => %{"body" => "hello from api bot"}} = json_response(post_conn, 201)

    list_conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> get(~p"/api/v1/channels/#{channel.id}/messages")

    assert %{"data" => [%{"body" => "hello from api bot"} | _]} = json_response(list_conn, 200)
  end

  test "bot API returns validation errors for invalid metadata", _context do
    actor =
      owner_fixture(%{
        email: "bot-api-validation-actor@example.com",
        username: "bot_api_validation_actor"
      })

    role =
      role_fixture(%{
        name: "Bot Speaker 2",
        permissions: PermissionBits.combine([:view_channel, :send_messages])
      })

    channel = channel_fixture(%{name: "Validation Channel", slug: unique_slug()})
    bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})
    {:ok, %{token: bot_token}} = Bots.create_bot_token(bot_user, %{"label" => "api"}, actor)

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> post(~p"/api/v1/channels/#{channel.id}/messages", %{
        message: %{body: "hello from api bot", metadata: "{"}
      })

    assert %{"error" => %{"code" => "invalid_message", "details" => %{"metadata" => [_ | _]}}} =
             json_response(conn, 422)
  end

  test "bot API returns rich message payloads", _context do
    actor =
      owner_fixture(%{email: "bot-api-rich-actor@example.com", username: "bot_api_rich_actor"})

    role =
      role_fixture(%{
        name: "Bot Rich Speaker",
        permissions: PermissionBits.combine([:view_channel, :send_messages])
      })

    channel = channel_fixture(%{name: "Rich Payload Channel", slug: unique_slug()})
    replied_user = user_fixture(%{email: "replied@example.com", username: "replied_user"})
    _replied_user_role = member_role_fixture(replied_user, role)
    reply_target = message_fixture(channel, replied_user, %{body: "seed reply target"})
    bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})
    {:ok, %{token: bot_token}} = Bots.create_bot_token(bot_user, %{"label" => "api"}, actor)

    post_conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> post(~p"/api/v1/channels/#{channel.id}/messages", %{
        message: %{
          body: "rich payload hello",
          reply_to_id: reply_target.id,
          metadata: %{"entities" => [%{"type" => "mention", "id" => replied_user.id}]}
        }
      })

    assert %{
             "data" => %{
               "body" => "rich payload hello",
               "author" => %{"id" => bot_id, "username" => bot_username, "bot" => true},
               "channel" => %{"id" => channel_id, "kind" => "text"},
               "reply_to" => %{"id" => reply_to_id, "author" => %{"id" => replied_author_id}},
               "reply_to_id" => echoed_reply_to_id
             }
           } = json_response(post_conn, 201)

    assert bot_id == bot_user.id
    assert bot_username == bot_user.username
    assert channel_id == channel.id
    assert reply_to_id == reply_target.id
    assert echoed_reply_to_id == reply_target.id
    assert replied_author_id == replied_user.id
  end

  test "bot token can create and fetch public threads through API", _context do
    actor =
      owner_fixture(%{
        email: "bot-api-thread-actor@example.com",
        username: "bot_api_thread_actor"
      })

    role =
      role_fixture(%{
        name: "Bot Thread Speaker",
        permissions:
          PermissionBits.combine([:view_channel, :send_messages, :create_public_threads])
      })

    channel = channel_fixture(%{name: "Thread Host", slug: unique_slug()})
    starter = message_fixture(channel, actor, %{body: "starter message"})
    bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})
    {:ok, %{token: bot_token}} = Bots.create_bot_token(bot_user, %{"label" => "api"}, actor)

    create_conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> post(~p"/api/v1/messages/#{starter.id}/threads", %{
        thread: %{name: "Bot support thread"}
      })

    assert %{
             "data" => %{
               "id" => thread_id,
               "name" => "Bot support thread",
               "kind" => "thread_public",
               "parent_channel_id" => parent_channel_id,
               "starter_message_id" => starter_message_id,
               "starter_message" => %{"id" => starter_payload_id},
               "parent_channel" => %{"id" => parent_payload_id, "kind" => "text"}
             }
           } = json_response(create_conn, 201)

    assert parent_channel_id == channel.id
    assert starter_message_id == starter.id
    assert starter_payload_id == starter.id
    assert parent_payload_id == channel.id
    assert %{} = Chat.get_thread_for_starter_message(bot_scope_for(bot_user, actor), starter.id)

    get_conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> get(~p"/api/v1/messages/#{starter.id}/thread")

    assert %{"data" => %{"id" => fetched_thread_id, "starter_message_id" => fetched_starter_id}} =
             json_response(get_conn, 200)

    assert fetched_thread_id == thread_id
    assert fetched_starter_id == starter.id
  end

  test "thread endpoint returns not found for missing starter thread", _context do
    actor =
      owner_fixture(%{email: "bot-api-thread-miss@example.com", username: "bot_api_thread_miss"})

    role =
      role_fixture(%{
        name: "Bot Thread Reader",
        permissions: PermissionBits.combine([:view_channel, :send_messages])
      })

    channel = channel_fixture(%{name: "Thread Query Host", slug: unique_slug()})
    starter = message_fixture(channel, actor, %{body: "no thread yet"})
    bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})
    {:ok, %{token: bot_token}} = Bots.create_bot_token(bot_user, %{"label" => "api"}, actor)

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{bot_token}")
      |> get(~p"/api/v1/messages/#{starter.id}/thread")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "events starts with enriched ready payload", _context do
    actor =
      owner_fixture(%{email: "bot-api-sse-ready@example.com", username: "bot_api_sse_ready"})

    bot_user = bot_fixture(actor)

    {conn, ref} =
      Phoenix.ConnTest.build_conn()
      |> TestStreamAdapter.wrap()

    conn =
      assign(conn, :current_bot_scope, bot_scope_for(bot_user, actor))

    task =
      Task.async(fn ->
        catch_exit(BotController.events(conn, %{}))
      end)

    assert_receive {:plug_conn, :sent}
    assert_receive {^ref, :chunk, ready_chunk}
    Task.shutdown(task, :brutal_kill)

    assert ready_chunk =~ "event: ready\n"
    assert ready_chunk =~ ~s("id":"#{bot_user.id}")
    assert ready_chunk =~ ~s("username":"#{bot_user.username}")
    assert ready_chunk =~ ~s("display_name":"#{bot_user.display_name}")
    assert ready_chunk =~ ~s("bot":true)
  end

  test "events stream rich message and thread payloads", _context do
    actor =
      owner_fixture(%{email: "bot-api-sse-events@example.com", username: "bot_api_sse_events"})

    role =
      role_fixture(%{
        name: "Bot SSE Role",
        permissions:
          PermissionBits.combine([
            :view_channel,
            :send_messages,
            :create_public_threads,
            :send_messages_in_threads
          ])
      })

    channel = channel_fixture(%{name: "SSE Channel", slug: unique_slug()})
    reply_author = user_fixture(%{email: "sse-reply@example.com", username: "sse_reply"})
    _reply_author_role = member_role_fixture(reply_author, role)
    reply_target = message_fixture(channel, reply_author, %{body: "reply seed"})
    _actor_role = member_role_fixture(actor, role)
    starter = message_fixture(channel, actor, %{body: "start a thread"})
    bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})

    {conn, ref} =
      Phoenix.ConnTest.build_conn()
      |> TestStreamAdapter.wrap()

    conn =
      assign(conn, :current_bot_scope, bot_scope_for(bot_user, actor))

    task =
      Task.async(fn ->
        catch_exit(BotController.events(conn, %{}))
      end)

    assert_receive {:plug_conn, :sent}
    assert_receive {^ref, :chunk, _ready_chunk}

    {:ok, %{message: created_message}} =
      Bots.command_send_message(
        bot_scope_for(bot_user, actor),
        %{
          "channel_id" => channel.id,
          "body" => "stream me",
          "reply_to_id" => reply_target.id,
          "metadata" => %{"source" => "sse-test"}
        }
      )

    {:ok, thread} =
      Chat.create_public_thread(bot_scope_for(bot_user, actor), starter.id, %{
        "name" => "SSE thread"
      })

    assert_receive {^ref, :chunk, message_chunk}
    assert_receive {^ref, :chunk, thread_chunk}

    thread_message = message_fixture(thread, actor, %{body: "inside the new thread"})
    assert_receive {^ref, :chunk, thread_message_chunk}

    Task.shutdown(task, :brutal_kill)

    assert thread_message_chunk =~ "event: message.created\n"
    assert thread_message_chunk =~ ~s("id":"#{thread_message.id}")

    assert message_chunk =~ "event: message.created\n"
    assert message_chunk =~ ~s("id":"#{created_message.id}")
    assert message_chunk =~ ~s("reply_to_id":"#{reply_target.id}")
    assert message_chunk =~ ~s("author":{"id":"#{bot_user.id}")
    assert message_chunk =~ ~s("channel":{"id":"#{channel.id}")
    assert message_chunk =~ ~s("reply_to":{"id":"#{reply_target.id}")

    assert thread_chunk =~ "event: thread.created\n"
    assert thread_chunk =~ ~s("id":"#{thread.id}")
    assert thread_chunk =~ ~s("starter_message_id":"#{starter.id}")
    assert thread_chunk =~ ~s("parent_channel":{"id":"#{channel.id}")
  end

  test "events skip channels and threads the bot cannot view", _context do
    actor =
      owner_fixture(%{email: "bot-api-sse-hidden@example.com", username: "bot_api_sse_hidden"})

    role =
      role_fixture(%{
        name: "Bot SSE Hidden Role",
        permissions:
          PermissionBits.combine([
            :view_channel,
            :send_messages,
            :create_public_threads,
            :send_messages_in_threads
          ])
      })

    _actor_role = member_role_fixture(actor, role)
    bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})
    visible_channel = channel_fixture(%{name: "SSE Visible", slug: unique_slug()})
    hidden_channel = channel_fixture(%{name: "SSE Hidden", slug: unique_slug()})

    channel_permission_overwrite_fixture(hidden_channel, %{
      user_id: bot_user.id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    hidden_starter = message_fixture(hidden_channel, actor, %{body: "hidden starter"})
    hidden_thread = thread_fixture(hidden_channel, hidden_starter, actor)

    {conn, ref} =
      Phoenix.ConnTest.build_conn()
      |> TestStreamAdapter.wrap()

    conn =
      assign(conn, :current_bot_scope, bot_scope_for(bot_user, actor))

    task =
      Task.async(fn ->
        catch_exit(BotController.events(conn, %{}))
      end)

    assert_receive {:plug_conn, :sent}
    assert_receive {^ref, :chunk, _ready_chunk}

    _hidden_message = message_fixture(hidden_channel, actor, %{body: "not for the bot"})
    _hidden_thread_message = message_fixture(hidden_thread, actor, %{body: "not for the bot"})
    visible_message = message_fixture(visible_channel, actor, %{body: "for the bot"})

    # Each process receives one sender's events in send order, so the first chunk after the
    # hidden posts shows whether either of them was streamed.
    assert_receive {^ref, :chunk, next_chunk}
    Task.shutdown(task, :brutal_kill)

    assert next_chunk =~ ~s("id":"#{visible_message.id}")
  end

  test "events answers 401 when the bot's membership ended after the token was checked" do
    actor = owner_fixture(%{email: "bot-api-deact@example.com", username: "bot_api_deact"})
    bot_user = bot_fixture(actor)
    scope = bot_scope_for(bot_user, actor)

    Repo.update_all(from(m in Membership, where: m.user_id == ^bot_user.id),
      set: [deactivated_at: DateTime.utc_now()]
    )

    conn =
      Phoenix.ConnTest.build_conn()
      |> assign(:current_bot_scope, scope)
      |> BotController.events(%{})

    assert conn.status == 401
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  describe "events reauthorization" do
    setup do
      actor =
        owner_fixture(%{email: "bot-api-reauth@example.com", username: "bot_api_reauth"})

      role =
        role_fixture(%{
          name: "Bot Reauth Role",
          permissions: PermissionBits.combine([:view_channel, :send_messages])
        })

      _actor_role = member_role_fixture(actor, role)
      bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})
      {:ok, %{token: token}} = Bots.create_bot_token(bot_user, %{"label" => "sse"}, actor)

      %{actor: actor, role: role, bot_user: bot_user, token: token}
    end

    test "a revoked token closes the stream", %{actor: actor, token: token} do
      {task, ref} = start_stream(token)
      assert_receive {^ref, :chunk, "event: ready" <> _}

      {:ok, %Rfchat.Accounts.Scope{bot_token_id: bot_token_id}} =
        Bots.get_bot_scope_by_token(token)

      bot_token = Rfchat.Repo.get!(Rfchat.Chat.BotToken, bot_token_id)
      {:ok, _revoked} = Bots.revoke_bot_token(bot_token, actor)

      send(task.pid, :reauthorize)

      assert_receive {^ref, :chunk, closed_chunk}
      assert closed_chunk =~ "event: closed\n"
      assert closed_chunk =~ ~s("reason":"token_revoked")
      assert %Plug.Conn{} = Task.await(task)
    end

    test "a valid token keeps the stream open with a keepalive", %{token: token} do
      {task, ref} = start_stream(token)
      assert_receive {^ref, :chunk, "event: ready" <> _}

      send(task.pid, :reauthorize)
      assert_receive {^ref, :chunk, ": keepalive\n\n"}

      assert Task.yield(task, 0) == nil
      Task.shutdown(task, :brutal_kill)
    end

    test "a channel the bot lost view of is unsubscribed on reauthorization", %{
      actor: actor,
      bot_user: bot_user,
      token: token
    } do
      channel = channel_fixture(%{name: "Reauth Channel", slug: unique_slug()})

      {task, ref} = start_stream(token)
      assert_receive {^ref, :chunk, "event: ready" <> _}

      # The sentinel channel must exist before reauthorization: the resync subscribes only the
      # channels visible at that moment, so a channel created afterwards would never stream.
      sentinel_channel = channel_fixture(%{name: "Reauth Visible", slug: unique_slug()})

      channel_permission_overwrite_fixture(channel, %{
        user_id: bot_user.id,
        deny_permissions: PermissionBits.combine([:view_channel])
      })

      send(task.pid, :reauthorize)
      assert_receive {^ref, :chunk, ": keepalive\n\n"}

      _hidden = message_fixture(channel, actor, %{body: "no longer visible"})
      sentinel = message_fixture(sentinel_channel, actor, %{body: "still visible"})

      assert_receive {^ref, :chunk, next_chunk}
      Task.shutdown(task, :brutal_kill)

      assert next_chunk =~ ~s("id":"#{sentinel.id}")
    end

    defp start_stream(token) do
      {conn, ref} =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> TestStreamAdapter.wrap()

      {:ok, scope} = Bots.get_bot_scope_by_token(token)
      conn = assign(conn, :current_bot_scope, scope)

      task = Task.async(fn -> BotController.events(conn, %{}) end)
      assert_receive {:plug_conn, :sent}
      {task, ref}
    end
  end

  test "bot management endpoints do not treat human users as bots", %{conn: conn} do
    _owner = owner_fixture(%{email: "api-bot-owner-2@example.com", username: "api_bot_owner_2"})

    admin_role =
      role_fixture(%{
        name: "Bot Admin Two",
        permissions: PermissionBits.combine([:manage_bots])
      })

    user = user_fixture(%{email: "api-bot-admin-2@example.com", username: "api_bot_admin_2"})
    human = user_fixture(%{email: "api-human@example.com", username: "api_human"})
    _member_role = member_role_fixture(user, admin_role)

    token = Rfchat.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:live_socket_id, "users_sessions:bot-admin-two")

    conn = get(conn, ~p"/api/v1/bots/#{human.id}/tokens")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  defp bot_scope_for(bot_user, actor) do
    {:ok, %{token: token}} = Bots.create_bot_token(bot_user, %{"label" => "test"}, actor)
    {:ok, scope} = Bots.get_bot_scope_by_token(token)
    scope
  end
end
