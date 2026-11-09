defmodule RfchatWeb.UserSessionController do
  use RfchatWeb, :controller

  alias Rfchat.Accounts
  alias Rfchat.Accounts.LoginRateLimiter
  alias RfchatWeb.UserAuth

  # The registration form signs the new account in by posting here with `_action=registered`, so
  # every password check goes through the login limiter.
  def create(
        conn,
        %{"user" => %{"email" => email, "password" => password} = user_params} = params
      ) do
    ip_address = conn.remote_ip |> :inet.ntoa() |> to_string()

    case LoginRateLimiter.check_attempt(ip_address, email) do
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
            conn
            |> put_flash(:error, "Invalid email or password.")
            |> redirect(to: ~p"/login")

          user ->
            :ok = LoginRateLimiter.clear_attempts(ip_address, email)

            conn
            |> welcome(params["_action"], user)
            |> UserAuth.log_in_user(user, %{
              "remember_me" => Map.get(user_params, "remember_me", "false")
            })
        end
    end
  end

  defp welcome(conn, "registered", _user), do: put_flash(conn, :info, "Account created")

  defp welcome(conn, _action, _user), do: conn

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
