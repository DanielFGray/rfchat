defmodule RfchatWeb.UserRegistrationController do
  use RfchatWeb, :controller

  alias Rfchat.Accounts
  alias RfchatWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_flash(:error, "Account created, but automatic sign-in failed. Please log in.")
        |> redirect(to: ~p"/login")

      user ->
        conn
        |> put_flash(:info, registration_message(user))
        |> UserAuth.log_in_user(user, %{
          "remember_me" => Map.get(user_params, "remember_me", "true")
        })
    end
  end

  defp registration_message(user) do
    if user.membership && user.membership.is_owner do
      "Account created. You are now signed in as the server owner."
    else
      "Account created. You are now signed in."
    end
  end
end
