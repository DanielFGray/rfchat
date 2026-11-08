defmodule RfchatWeb.API.BotApiInputTest do
  use RfchatWeb.ConnCase

  import Rfchat.ChatFixtures

  alias Rfchat.Bots
  alias Rfchat.Chat.PermissionBits

  describe "bot and token visibility" do
    setup do
      owner = owner_fixture()
      high_role = role_fixture(%{permissions: 0, position: 10})
      high_bot = bot_fixture(owner, %{"role_ids" => [high_role.id]})
      low_bot = bot_fixture(owner, %{})
      manager = member_fixture(PermissionBits.combine([:manage_bots]), 5)

      %{owner: owner, manager: manager, high_bot: high_bot, low_bot: low_bot}
    end

    test "the bot list omits bots ranked above the actor", %{manager: manager} = context do
      conn = session_conn(manager)
      ids = conn |> get(~p"/api/v1/bots") |> json_response(200) |> bot_ids()

      assert context.low_bot.id in ids
      refute context.high_bot.id in ids
    end

    test "the owner sees every bot in the list", %{owner: owner} = context do
      conn = session_conn(owner)
      ids = conn |> get(~p"/api/v1/bots") |> json_response(200) |> bot_ids()

      assert context.high_bot.id in ids
      assert context.low_bot.id in ids
    end

    test "the token list for a bot above the actor is 404, the same as a missing bot",
         %{manager: manager} = context do
      conn = session_conn(manager)

      assert %{"error" => %{"code" => "not_found"}} =
               conn
               |> get(~p"/api/v1/bots/#{context.high_bot.id}/tokens")
               |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} =
               conn
               |> get(~p"/api/v1/bots/#{Ecto.UUID.generate()}/tokens")
               |> json_response(404)
    end

    test "the token list for a bot the actor controls is returned",
         %{manager: manager} = context do
      _token = create_token!(context.low_bot, manager)

      assert [_] =
               session_conn(manager)
               |> get(~p"/api/v1/bots/#{context.low_bot.id}/tokens")
               |> json_response(200)
               |> Map.fetch!("data")
    end
  end

  describe "token expiry" do
    setup do
      owner = owner_fixture()
      bot = bot_fixture(owner, %{})
      %{owner: owner, bot: bot}
    end

    test "an absent expiry creates a token that never expires", %{owner: owner, bot: bot} do
      conn = post(session_conn(owner), ~p"/api/v1/bots/#{bot.id}/tokens", %{token: %{}})

      assert json_response(conn, 201)
      assert [%{expires_at: nil}] = Bots.list_bot_tokens(bot)
    end

    test "a blank form expiry creates a token that never expires", %{owner: owner, bot: bot} do
      conn =
        post(session_conn(owner), ~p"/api/v1/bots/#{bot.id}/tokens", %{
          token: %{"expires_in_days" => ""}
        })

      assert json_response(conn, 201)
      assert [%{expires_at: nil}] = Bots.list_bot_tokens(bot)
    end

    test "an integer or form string from 1 to 365 sets an expiry", %{owner: owner, bot: bot} do
      for days <- [1, "30", 365] do
        conn =
          post(session_conn(owner), ~p"/api/v1/bots/#{bot.id}/tokens", %{
            token: %{"expires_in_days" => days}
          })

        assert json_response(conn, 201)
      end

      assert Enum.all?(Bots.list_bot_tokens(bot), &(&1.expires_at != nil))
    end

    test "an expiry outside 1..365, or not an integer, is a 422 and creates no token",
         %{owner: owner, bot: bot} do
      for value <- [0, -5, 366, "abc", 1.5] do
        conn =
          post(session_conn(owner), ~p"/api/v1/bots/#{bot.id}/tokens", %{
            token: %{"expires_in_days" => value}
          })

        assert %{"error" => %{"code" => "invalid_bot_token", "details" => details}} =
                 json_response(conn, 422)

        assert [_ | _] = details["expires_in_days"]
      end

      assert Bots.list_bot_tokens(bot) == []
    end
  end

  describe "malformed ids" do
    setup do
      owner = owner_fixture()
      bot = bot_fixture(owner, %{})
      channel = channel_fixture()
      {:ok, %{token: bot_token}} = Bots.create_bot_token(bot, %{}, owner)
      %{owner: owner, bot: bot, channel: channel, bot_token: bot_token}
    end

    test "a non-UUID token id is 404 on revoke", %{owner: owner} do
      conn = delete(session_conn(owner), ~p"/api/v1/bot_tokens/not-a-uuid")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "a non-UUID bot id is 404 on the token list and token create",
         %{owner: owner} do
      conn = session_conn(owner)

      assert %{"error" => %{"code" => "not_found"}} =
               conn |> get(~p"/api/v1/bots/not-a-uuid/tokens") |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} =
               conn
               |> post(~p"/api/v1/bots/not-a-uuid/tokens", %{token: %{}})
               |> json_response(404)
    end

    test "a non-UUID message id is 404 on the thread route", %{bot_token: bot_token} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> get(~p"/api/v1/messages/not-a-uuid/thread")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "a non-UUID channel id is 404 on user message create", %{owner: owner} do
      conn =
        session_conn(owner)
        |> post(~p"/api/v1/user/channels/not-a-uuid/messages", %{message: %{body: "hi"}})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "tokens of a deleted bot" do
    test "revoking a token whose bot was deleted is 404, not a crash" do
      owner = owner_fixture()
      bot = bot_fixture(owner, %{})
      {:ok, %{bot_token: bot_token}} = Bots.create_bot_token(bot, %{}, owner)

      assert %{"data" => _} =
               session_conn(owner)
               |> delete(~p"/api/v1/bots/#{bot.id}")
               |> json_response(200)

      conn = delete(session_conn(owner), ~p"/api/v1/bot_tokens/#{bot_token.id}")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "non-object bodies" do
    setup do
      owner = owner_fixture()
      bot = bot_fixture(owner, %{})
      channel = channel_fixture()
      {:ok, %{token: bot_token}} = Bots.create_bot_token(bot, %{}, owner)
      %{owner: owner, bot: bot, channel: channel, bot_token: bot_token}
    end

    test "a token body that is not an object, or is missing, is 422",
         %{owner: owner, bot: bot} do
      conn = session_conn(owner)

      assert %{"error" => %{"code" => "invalid_params"}} =
               conn
               |> post(~p"/api/v1/bots/#{bot.id}/tokens", %{token: "abc"})
               |> json_response(422)

      assert %{"error" => %{"code" => "invalid_params"}} =
               conn
               |> post(~p"/api/v1/bots/#{bot.id}/tokens", %{})
               |> json_response(422)
    end

    test "a bot body that is not an object is 422", %{owner: owner} do
      conn = post(session_conn(owner), ~p"/api/v1/bots", %{bot: "x"})

      assert %{"error" => %{"code" => "invalid_params"}} = json_response(conn, 422)
    end

    test "a message body that is not an object is 422 for a user", %{
      owner: owner,
      channel: channel
    } do
      conn =
        session_conn(owner)
        |> post(~p"/api/v1/user/channels/#{channel.id}/messages", %{message: "hi"})

      assert %{"error" => %{"code" => "invalid_params"}} = json_response(conn, 422)
    end

    test "a message body that is not an object is 422 for a bot", %{
      channel: channel,
      bot_token: bot_token
    } do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/v1/channels/#{channel.id}/messages", %{message: "hi"})

      assert %{"error" => %{"code" => "invalid_params"}} = json_response(conn, 422)
    end

    test "a thread body that is not an object is 422 for a bot", %{bot_token: bot_token} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{bot_token}")
        |> post(~p"/api/v1/messages/#{Ecto.UUID.generate()}/threads", %{thread: "x"})

      assert %{"error" => %{"code" => "invalid_thread"}} = json_response(conn, 422)
    end
  end

  defp session_conn(user) do
    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Rfchat.Accounts.generate_user_session_token(user))
  end

  defp member_fixture(permissions, position) do
    role = role_fixture(%{permissions: permissions, position: position})
    member = user_fixture()
    member_role_fixture(member, role)
    member
  end

  defp create_token!(bot, actor) do
    {:ok, %{token: token}} = Bots.create_bot_token(bot, %{}, actor)
    token
  end

  defp bot_ids(%{"data" => bots}), do: Enum.map(bots, & &1["id"])
end
