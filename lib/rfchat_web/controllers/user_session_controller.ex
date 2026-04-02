defmodule RfchatWeb.UserSessionController do
  use RfchatWeb, :controller

  alias Rfchat.Accounts
  alias Rfchat.Accounts.LoginRateLimiter
  alias RfchatWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
    ip_address = conn.remote_ip |> :inet.ntoa() |> to_string()

    case LoginRateLimiter.allow_login_attempt(ip_address, email) do
      {:error, retry_after_seconds} ->
        conn
        |> put_flash(
          :error,
          "Too many login attempts. Try again in #{retry_after_seconds} seconds."
        )
        |> redirect(to: ~p"/login")

      :ok ->
        case Accounts.get_user_by_email_and_password(email, password) do
          nil ->
            :ok = LoginRateLimiter.record_failed_attempt(ip_address, email)

            conn
            |> put_flash(:error, "Invalid email or password.")
            |> redirect(to: ~p"/login")

          user ->
            :ok = LoginRateLimiter.clear_attempts(ip_address, email)

            UserAuth.log_in_user(conn, user, %{
              "remember_me" => Map.get(user_params, "remember_me", "false")
            })
        end
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
