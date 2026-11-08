defmodule RfchatWeb.API.BotAuthorityTest do
  use RfchatWeb.ConnCase

  import Rfchat.ChatFixtures

  alias Rfchat.Bots
  alias Rfchat.Chat.PermissionBits

  test "a manage_bots-only member cannot create an administrator bot over the API", %{
    conn: conn
  } do
    _owner = owner_fixture()
    admin_role = role_fixture(%{permissions: PermissionBits.combine([:administrator])})
    manager_role = role_fixture(%{permissions: PermissionBits.combine([:manage_bots])})
    manager = user_fixture()
    member_role_fixture(manager, manager_role)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, Rfchat.Accounts.generate_user_session_token(manager))
      |> post(~p"/api/v1/bots", %{
        bot: %{
          display_name: "Escalator",
          username: "escalator",
          email: "escalator@example.com",
          role_ids: [admin_role.id]
        }
      })

    assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    assert Bots.list_controllable_bot_users(manager) == []
  end
end
