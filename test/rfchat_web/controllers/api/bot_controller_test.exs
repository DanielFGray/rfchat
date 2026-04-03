defmodule RfchatWeb.API.BotControllerTest do
  use RfchatWeb.ConnCase

  import Rfchat.ChatFixtures

  alias Rfchat.Bots
  alias Rfchat.Chat.PermissionBits

  test "authenticated admins can create bots", %{conn: conn} do
    _owner = user_fixture(%{email: "api-bot-owner@example.com", username: "api_bot_owner"})

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
    actor = user_fixture(%{email: "bot-api-actor@example.com", username: "bot_api_actor"})

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
      user_fixture(%{
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

  test "bot management endpoints do not treat human users as bots", %{conn: conn} do
    _owner = user_fixture(%{email: "api-bot-owner-2@example.com", username: "api_bot_owner_2"})

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
end
