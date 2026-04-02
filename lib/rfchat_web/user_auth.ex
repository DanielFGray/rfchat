defmodule RfchatWeb.UserAuth do
  use RfchatWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Phoenix.LiveView
  alias Rfchat.Accounts

  @remember_me_cookie "_rfchat_user_remember_me"
  @remember_me_options [sign: true, max_age: 60 * 60 * 24 * 30, same_site: "Lax"]

  def init(action), do: action

  def call(conn, action) do
    apply(__MODULE__, action, [conn, []])
  end

  def log_in_user(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user, session_metadata(conn))
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      RfchatWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/login")
  end

  def fetch_current_scope_for_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)

    conn
    |> Plug.Conn.assign(:current_user, user)
    |> Plug.Conn.assign(:current_scope, user && Accounts.user_scope(user))
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_user do
      conn
    else
      conn
      |> put_flash(:error, "Please log in to continue.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns.current_user do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt,
       socket
       |> LiveView.put_flash(:error, "Please log in to continue.")
       |> LiveView.redirect(to: ~p"/login")}
    end
  end

  def on_mount(:redirect_if_user_is_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_user do
      {:halt, LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    user =
      Map.get(session, "user_token") && Accounts.get_user_by_session_token(session["user_token"])

    socket
    |> Phoenix.Component.assign(:current_user, user)
    |> Phoenix.Component.assign(:current_scope, user && Accounts.user_scope(user))
  end

  defp maybe_store_return_to(%Plug.Conn{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
  defp signed_in_path(_conn), do: ~p"/"

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params), do: conn

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_session(conn, :user_token, token)}
      else
        {nil, conn}
      end
    end
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(
      :live_socket_id,
      "users_sessions:#{Base.url_encode64(:crypto.strong_rand_bytes(32))}"
    )
  end

  defp session_metadata(conn) do
    %{
      user_agent: conn |> get_req_header("user-agent") |> List.first(),
      ip_address: remote_ip_to_string(conn.remote_ip)
    }
  end

  defp remote_ip_to_string(nil), do: nil
  defp remote_ip_to_string(remote_ip), do: remote_ip |> :inet.ntoa() |> to_string()
end
