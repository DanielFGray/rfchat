defmodule RfchatWeb.BannedLiveTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures

  alias Rfchat.Chat.Membership
  alias Rfchat.Repo

  test "log out link submits DELETE to /logout", %{conn: conn} do
    conn = login_excluded_user(conn, "banned_link", %{"banned" => true})

    {:ok, view, _html} = live(conn, ~p"/banned")

    assert has_element?(view, "#banned-page #logout-link[href='/logout'][data-method='delete']")
  end

  test "a banned member sees the ban page with the reason and ban time", %{conn: conn} do
    conn =
      login_excluded_user(conn, "banned_page", %{
        "banned" => true,
        "ban_reason" => "repeat abuse"
      })

    {:ok, view, _html} = live(conn, ~p"/banned")

    assert has_element?(view, "#banned-page #banned-heading")
    assert has_element?(view, "#banned-page #banned-at")
    assert has_element?(view, "#banned-page #ban-reason")
    assert render(view) =~ "repeat abuse"
    refute has_element?(view, "#removed-page")
    refute has_element?(view, "#removed-heading")
  end

  test "a kicked member sees the removal page and no ban details", %{conn: conn} do
    conn = login_excluded_user(conn, "kicked_page", %{"kicked" => true})

    {:ok, view, _html} = live(conn, ~p"/banned")

    assert has_element?(view, "#removed-page #removed-heading")
    assert has_element?(view, "#removed-page #logout-link[href='/logout'][data-method='delete']")
    refute has_element?(view, "#banned-page")
    refute has_element?(view, "#banned-heading")
    refute has_element?(view, "#banned-at")
    refute has_element?(view, "#ban-reason")
  end

  defp login_excluded_user(conn, name, flags) do
    user =
      user_fixture(%{
        email: "#{name}@example.com",
        username: name,
        display_name: name
      })

    user = user_with_membership!(user.id)

    user.membership
    |> Membership.deactivate_changeset(DateTime.utc_now(), flags)
    |> Repo.update!()

    post(conn, ~p"/login", %{
      user: %{email: user.email, password: "supersecurepass"}
    })
  end
end
