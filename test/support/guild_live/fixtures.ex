defmodule RfchatWeb.GuildLiveFixtures do
  @moduledoc false

  alias Rfchat.Chat

  import Rfchat.ChatFixtures

  def log_in_member_user(conn, suffix \\ "default") do
    _owner =
      user_fixture(%{
        email: "owner-guildlive-#{suffix}@example.com",
        username: "owner_#{suffix}",
        display_name: "Owner Guildlive User #{suffix}"
      })

    user =
      user_fixture(%{
        email: "guildlive-#{suffix}@example.com",
        username: "member_#{suffix}",
        display_name: "Guildlive User #{suffix}"
      })

    token = Rfchat.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:test")
  end

  def log_in_owner_user(conn) do
    user =
      user_fixture(%{
        email: "guildlive-owner@example.com",
        username: "guildlive_owner",
        display_name: "Guildlive Owner"
      })

    token = Rfchat.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:owner")
  end

  def current_user_from_conn(conn) do
    token = Plug.Conn.get_session(conn, :user_token)
    Rfchat.Accounts.get_user_by_session_token(token)
  end

  def category_id(slug), do: Chat.get_channel_by_slug!(slug).id
end
