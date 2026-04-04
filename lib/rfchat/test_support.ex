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

  defp execute("list_channels", _payload) do
    channels =
      Chat.list_channels()
      |> Enum.filter(&(&1.kind in [:text, :announcement]))
      |> Enum.map(fn channel ->
        %{id: channel.id, name: channel.name, slug: channel.slug, kind: channel.kind}
      end)

    %{channels: channels}
  end

  defp execute("create_bot_with_token", payload) do
    actor = owner_user!()

    username = payload["username"] || "test_bot_#{System.unique_integer([:positive])}"

    {:ok, bot_user} =
      Rfchat.Bots.create_bot(
        %{
          username: username,
          display_name: payload["display_name"] || username,
          email: payload["email"] || "#{username}@bot.local"
        },
        actor
      )

    {:ok, %{token: token}} =
      Rfchat.Bots.create_bot_token(
        bot_user,
        %{label: payload["label"] || "k6-load-test"},
        actor
      )

    %{
      bot: %{id: bot_user.id, username: bot_user.username},
      token: token
    }
  end

  defp execute("create_message", payload) do
    channel_slug = payload["channel_slug"] || raise "channel_slug is required"
    username = payload["username"] || raise "username is required"
    body = payload["body"] || raise "body is required"

    channel = Chat.get_channel_by_slug!(channel_slug)
    user = Repo.get_by!(User, username: username)

    {:ok, message} = Chat.create_message(channel, user, %{"body" => body})

    %{
      message: %{
        id: message.id,
        channel_id: message.channel_id,
        body: message.body
      }
    }
  end

  defp execute("bulk_create_users", payload) do
    count = payload["count"] || 10
    offset = payload["offset"] || 0
    prefix = payload["prefix"] || "test_k6"
    password = payload["password"] || "LoadTest12345!"

    users =
      Enum.map(1..count, fn i ->
        n = offset + i
        username = "#{prefix}_#{n}"
        email = "#{username}@example.com"

        user =
          Accounts.get_user_by_email(email) ||
            Accounts.register_user!(%{
              email: email,
              username: username,
              display_name: "Load User #{n}",
              password: password
            })

        %{id: user.id, email: user.email, username: user.username}
      end)

    %{users: users, count: length(users)}
  end

  defp execute("clear_k6_data", _payload) do
    k6_user_ids =
      from(u in User,
        where: like(u.username, "test_k6_%") or like(u.username, "test_bot_%"),
        where: u.system == false,
        select: u.id
      )

    {msg_count, _} =
      Repo.delete_all(from(m in Message, where: m.author_id in subquery(k6_user_ids)))

    {user_count, _} =
      Repo.delete_all(
        from(u in User,
          where: like(u.username, "test_k6_%") or like(u.username, "test_bot_%"),
          where: u.system == false
        )
      )

    %{success: true, deleted_users: user_count, deleted_messages: msg_count}
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
