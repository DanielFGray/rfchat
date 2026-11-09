defmodule RfchatWeb.Plugs.RequireBotAuthTest do
  use RfchatWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Rfchat.ChatFixtures

  alias Rfchat.Bots
  alias Rfchat.Chat.Membership
  alias Rfchat.Repo
  alias RfchatWeb.Plugs.RequireBotAuth

  test "a token whose bot is deactivated gets the same 401 as an invalid token" do
    actor = owner_fixture(%{email: "plug-deact-owner@example.com", username: "plug_deact_owner"})
    bot_user = bot_fixture(actor)
    {:ok, %{token: token}} = Bots.create_bot_token(bot_user, %{"label" => "plug"}, actor)

    Repo.update_all(from(m in Membership, where: m.user_id == ^bot_user.id),
      set: [deactivated_at: DateTime.utc_now()]
    )

    deactivated =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> RequireBotAuth.call([])

    invalid =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer not-a-real-token")
      |> RequireBotAuth.call([])

    assert deactivated.status == 401
    assert deactivated.halted
    assert json_response(deactivated, 401) == json_response(invalid, 401)
  end
end
