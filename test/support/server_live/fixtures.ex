defmodule TavernWeb.ServerLiveFixtures do
  @moduledoc false

  import Tavern.ChatFixtures

  def log_in_member_user(conn, suffix \\ "default") do
    _owner =
      user_fixture(%{
        email: "owner-serverlive-#{suffix}@example.com",
        username: "owner_#{suffix}",
        display_name: "Owner Serverlive User #{suffix}"
      })

    user =
      user_fixture(%{
        email: "serverlive-#{suffix}@example.com",
        username: "member_#{suffix}",
        display_name: "Serverlive User #{suffix}"
      })

    token = Tavern.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:test")
  end

  def log_in_owner_user(conn) do
    user =
      owner_fixture(%{
        email: "serverlive-owner@example.com",
        username: "serverlive_owner",
        display_name: "Serverlive Owner"
      })

    token = Tavern.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:owner")
  end

  @max_hydration_renders 5

  @doc """
  Mounts ServerLive and waits until the connected mount's deferred hydration has run.

  A render is a synchronous call to the view, so it runs after every message already in the
  view's mailbox. The hydrate chain is two messages deep (`:hydrate_navigation` sends
  `:hydrate_unread_state`), so the helper renders once more after the shell reports hydrated.
  Returns `{:ok, view, html}` where `html` is the hydrated render.
  """
  defmacro live_hydrated(conn, path) do
    quote do
      with {:ok, view, _loading_html} <- Phoenix.LiveViewTest.live(unquote(conn), unquote(path)) do
        {:ok, view, TavernWeb.ServerLiveFixtures.await_hydration(view)}
      end
    end
  end

  @doc false
  def await_hydration(view, attempts_left \\ @max_hydration_renders)

  def await_hydration(_view, 0) do
    raise "ServerLive did not report data-hydrated=true on #server-shell within #{@max_hydration_renders} renders"
  end

  def await_hydration(view, attempts_left) do
    Phoenix.LiveViewTest.render(view)

    if Phoenix.LiveViewTest.has_element?(view, "#server-shell[data-hydrated=true]") do
      Phoenix.LiveViewTest.render(view)
    else
      await_hydration(view, attempts_left - 1)
    end
  end

  def current_user_from_conn(conn) do
    token = Plug.Conn.get_session(conn, :user_token)
    Tavern.Accounts.get_user_by_session_token(token)
  end

  def category_id(slug), do: channel_by_slug!(slug).id
end
