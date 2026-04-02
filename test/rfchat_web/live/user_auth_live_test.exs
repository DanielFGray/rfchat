defmodule RfchatWeb.UserAuthLiveTest do
  use RfchatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rfchat.Accounts.LoginRateLimiter
  alias Rfchat.Bootstrap
  import Rfchat.ChatFixtures

  setup do
    LoginRateLimiter.reset!()
    :ok
  end

  test "registration flow creates account and redirects to login", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/register")

    view
    |> form("#registration-form", %{
      user: %{
        email: "signup@example.com",
        username: "signup_user",
        display_name: "Signup User",
        password: "supersecurepass"
      }
    })
    |> render_submit()

    assert_redirect(view, ~p"/login")
  end

  test "first registration announces server owner status", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/register")

    view
    |> form("#registration-form", %{
      user: %{
        email: "owner-signup@example.com",
        username: "owner_signup",
        display_name: "Owner Signup",
        password: "supersecurepass"
      }
    })
    |> render_submit()

    assert_redirect(view, ~p"/login")

    owner =
      Rfchat.Accounts.get_user_by_email("owner-signup@example.com")
      |> Rfchat.Repo.preload(:membership)

    assert owner.membership.is_owner
  end

  test "login redirects authenticated user into guild shell", %{conn: conn} do
    user_fixture(%{
      email: "login@example.com",
      username: "login_user",
      display_name: "Login User"
    })

    {:ok, view, _html} = live(conn, ~p"/login")

    login_form =
      form(view, "#login-form", %{
        user: %{
          email: "login@example.com",
          password: "supersecurepass",
          remember_me: "true"
        }
      })

    render_submit(login_form)

    conn = follow_trigger_action(login_form, conn)

    assert redirected_to(conn) == ~p"/"
  end

  test "guild shell requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  test "login rate limiting blocks repeated invalid attempts", %{conn: conn} do
    user_fixture(%{email: "ratelimit@example.com", username: "ratelimit_user"})

    attempts =
      Enum.map(1..6, fn _attempt ->
        conn
        |> recycle()
        |> post(~p"/login", %{
          user: %{email: "ratelimit@example.com", password: "wrongpass", remember_me: "false"}
        })
      end)

    assert Phoenix.Flash.get(Enum.at(attempts, 4).assigns.flash, :error) ==
             "Invalid email or password."

    assert Phoenix.Flash.get(List.last(attempts).assigns.flash, :error) =~
             "Too many login attempts"
  end

  test "authenticated user can open guild shell and post as self", %{conn: conn} do
    Bootstrap.ensure_seed_data!()

    user_fixture(%{
      email: "guild@example.com",
      username: "guild_user",
      display_name: "Guild User"
    })

    {:ok, login_view, _html} = live(conn, ~p"/login")

    login_form =
      form(login_view, "#login-form", %{
        user: %{email: "guild@example.com", password: "supersecurepass"}
      })

    render_submit(login_form)

    conn = follow_trigger_action(login_form, conn)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#logout-link")
    assert render(view) =~ "@guild_user"

    html =
      view
      |> form("#message-form", %{message: %{body: "auth works"}})
      |> render_submit()

    assert html =~ "auth works"
    assert render(view) =~ "Guild User"
  end

  test "banned user login redirects to banned screen", %{conn: conn} do
    banned_user =
      user_fixture(%{
        email: "banned@example.com",
        username: "banned_user",
        display_name: "Banned User"
      })

    banned_user = Rfchat.Accounts.get_user_with_membership!(banned_user.id)

    banned_user.membership
    |> Rfchat.Chat.Membership.changeset(%{
      deactivated_at: DateTime.utc_now(),
      flags: %{"banned" => true, "ban_reason" => "repeat abuse"}
    })
    |> Rfchat.Repo.update!()

    {:ok, login_view, _html} = live(conn, ~p"/login")

    login_form =
      form(login_view, "#login-form", %{
        user: %{email: "banned@example.com", password: "supersecurepass"}
      })

    render_submit(login_form)

    conn = follow_trigger_action(login_form, conn)

    assert redirected_to(conn) == ~p"/banned"

    {:ok, banned_view, _html} = live(conn, ~p"/banned")
    assert render(banned_view) =~ "repeat abuse"
  end
end
