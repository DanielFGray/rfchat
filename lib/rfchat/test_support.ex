defmodule Rfchat.TestSupport do
  @moduledoc """
  Server-side test commands for E2E / Playwright tests.

  Every command receives a string-keyed payload (from `Jason.decode!/1`)
  and the current `Plug.Conn`. Commands return either:

    * `{:json, map}` – controller sends the map as JSON
    * `{:conn, conn}` – controller returns the conn as-is (e.g. login redirect)
  """

  import Ecto.Query, warn: false

  alias Rfchat.Accounts
  alias Rfchat.Accounts.LoginRateLimiter
  alias Rfchat.Chat
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  # ---------------------------------------------------------------------------
  # Public entry point
  # ---------------------------------------------------------------------------

  @doc """
  Dispatch a named command. Returns `{:json, data}` or `{:conn, conn}`.
  """
  def run_command(command, payload, conn)

  def run_command("login", payload, conn) do
    user = upsert_test_user!(payload)
    next = payload["next"] || "/"

    conn =
      conn
      |> Plug.Conn.put_session(:user_return_to, next)
      |> RfchatWeb.UserAuth.log_in_user(user)

    {:conn, conn}
  end

  def run_command(command, payload, _conn) do
    {:json, execute(command, payload)}
  end

  # ---------------------------------------------------------------------------
  # Commands (all return plain maps)
  # ---------------------------------------------------------------------------

  defp execute("reset_login_rate_limiter", _payload) do
    LoginRateLimiter.reset!()
    %{success: true}
  end

  defp execute("upsert_user", payload) do
    user = upsert_test_user!(payload)
    %{user: user_payload(user)}
  end

  defp execute("clear_test_users", _payload) do
    test_user_ids =
      from(u in User,
        where: like(u.username, "test_%") or like(u.username, "e2e_%"),
        select: u.id
      )

    # Messages have on_delete: :restrict on author_id, so delete them first.
    {msg_count, _} =
      Repo.delete_all(from(m in Message, where: m.author_id in subquery(test_user_ids)))

    # Everything else cascades from users.
    {user_count, _} =
      Repo.delete_all(
        from(u in User, where: like(u.username, "test_%") or like(u.username, "e2e_%"))
      )

    %{success: true, deleted_users: user_count, deleted_messages: msg_count}
  end

  defp execute("set_server_name", payload) do
    name = payload["name"] || raise "name is required"

    {:ok, settings} = Chat.update_server_settings(%{"name" => name}, owner_user!())

    %{server: %{name: settings.name, icon_url: Chat.server_icon_url(settings)}}
  end

  defp execute("get_server_branding", _payload) do
    settings = Chat.get_server_settings()
    %{server: %{name: settings.name, icon_url: Chat.server_icon_url(settings)}}
  end

  defp execute(command, _payload), do: raise("Command '#{command}' not understood.")

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp upsert_test_user!(payload) do
    email = payload["email"] || raise "email is required"
    username = payload["username"] || raise "username is required"

    ensure_safe_test_identity!(email, username)

    Accounts.get_user_by_email(email) ||
      normalize_user_attrs(payload, email, username)
      |> Accounts.register_user!()
  end

  defp normalize_user_attrs(payload, email, username) do
    %{
      email: email,
      username: username,
      display_name: payload["display_name"] || username,
      password: payload["password"] || "supersecurepass"
    }
  end

  defp ensure_safe_test_identity!(email, username) do
    unless String.ends_with?(email, "@example.com") do
      raise "test users must use an @example.com email"
    end

    unless String.starts_with?(username, "test_") or String.starts_with?(username, "e2e_") do
      raise "test usernames must start with 'test_' or 'e2e_'"
    end
  end

  defp owner_user! do
    User
    |> join(:inner, [user], membership in Membership, on: membership.user_id == user.id)
    |> where([_user, membership], membership.is_owner == true)
    |> preload([user, _membership], [:membership, member_roles: :role])
    |> limit(1)
    |> Repo.one!()
  end

  defp user_payload(user) do
    %{id: user.id, email: user.email, username: user.username, display_name: user.display_name}
  end
end
