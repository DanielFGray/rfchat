defmodule TavernWeb.UserSessionControllerTest do
  use TavernWeb.ConnCase, async: false

  alias Tavern.Chat.User
  alias Tavern.Repo

  test "login with an account that has no password hash returns invalid credentials", %{
    conn: conn
  } do
    %User{}
    |> User.account_changeset(%{
      email: "system-login@example.com",
      username: "system_login",
      display_name: "System Login"
    })
    |> Repo.insert!()

    conn =
      post(conn, ~p"/login", %{
        user: %{email: "system-login@example.com", password: "any-password"}
      })

    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
  end
end
