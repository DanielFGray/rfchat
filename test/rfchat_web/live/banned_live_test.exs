defmodule RfchatWeb.BannedLiveTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures

  alias Rfchat.Accounts
  alias Rfchat.Chat.Membership
  alias Rfchat.Repo

  test "log out link submits DELETE to /logout", %{conn: conn} do
    user =
      user_fixture(%{
        email: "banned-link@example.com",
        username: "banned_link",
        display_name: "Banned Link"
      })

    user = Accounts.get_user_with_membership!(user.id)

    user.membership
    |> Membership.deactivate_changeset(DateTime.utc_now(), %{"banned" => true})
    |> Repo.update!()

    conn =
      post(conn, ~p"/login", %{
        user: %{email: user.email, password: "supersecurepass"}
      })

    {:ok, view, _html} = live(conn, ~p"/banned")

    assert has_element?(view, "#banned-logout-link[href='/logout'][data-method='delete']")
  end
end
