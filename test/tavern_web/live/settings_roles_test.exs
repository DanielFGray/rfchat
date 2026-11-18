defmodule TavernWeb.SettingsRolesTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures

  alias Tavern.Accounts
  alias Tavern.Bootstrap
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Role
  alias Tavern.Repo

  setup do
    Bootstrap.ensure_seed_data!()

    manager_role =
      role_fixture(%{
        name: "Manager",
        position: 50,
        permissions: PermissionBits.combine([:view_channel, :send_messages, :manage_roles])
      })

    low_role =
      role_fixture(%{
        name: "Low",
        position: 10,
        permissions: PermissionBits.combine([:send_messages])
      })

    manager = user_fixture()
    member_role_fixture(manager, manager_role)

    %{manager: manager, manager_role: manager_role, low_role: low_role, member: user_fixture()}
  end

  test "the Roles tab is hidden from a member without manage_roles", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.member), ~p"/settings?tab=roles")

    refute has_element?(view, "#settings-tab-roles")
    refute has_element?(view, "#settings-view-roles")
    refute has_element?(view, "#open-member-roles-#{ctx.manager.id}")
  end

  test "a manager creates a role", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.manager), ~p"/settings?tab=roles")
    assert has_element?(view, "#settings-tab-roles")

    view
    |> form("#role-create-form", role_create: %{name: "Helpers", color: "#3366ff"})
    |> render_submit()

    role = Repo.get_by!(Role, name: "Helpers")
    assert role.color == 0x3366FF
    assert has_element?(view, "#role-row-#{role.id}")
    assert has_element?(view, "#role-edit-form")
  end

  test "a manager edits a role's permissions; bits they lack are disabled", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.manager), ~p"/settings?tab=roles")

    view |> element("#edit-role-#{ctx.low_role.id}") |> render_click()
    assert has_element?(view, "#role-permission-ban_members[disabled]")
    refute has_element?(view, "#role-permission-view_channel[disabled]")

    view
    |> form("#role-edit-form",
      role: %{
        name: "Lower",
        permissions: %{send_messages: "true", view_channel: "true"}
      }
    )
    |> render_submit()

    role = Repo.get!(Role, ctx.low_role.id)
    assert role.name == "Lower"
    assert role.permissions == PermissionBits.combine([:send_messages, :view_channel])
  end

  test "a manager reorders roles below them", %{conn: conn} = ctx do
    middle = role_fixture(%{name: "Middle", position: 30})
    {:ok, view, _html} = live(log_in_as(conn, ctx.manager), ~p"/settings?tab=roles")

    view |> element("#move-role-up-#{ctx.low_role.id}") |> render_click()

    assert Repo.get!(Role, ctx.low_role.id).position > Repo.get!(Role, middle.id).position
  end

  test "a manager deletes a role", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.manager), ~p"/settings?tab=roles")

    view |> element("#delete-role-#{ctx.low_role.id}") |> render_click()

    refute Repo.get(Role, ctx.low_role.id)
    refute has_element?(view, "#role-row-#{ctx.low_role.id}")
  end

  test "a manager gives and takes a member role", %{conn: conn} = ctx do
    member = ctx.member
    {:ok, view, _html} = live(log_in_as(conn, ctx.manager), ~p"/settings?tab=server")

    view |> element("#open-member-roles-#{member.id}") |> render_click()

    view
    |> form("#member-role-form-#{member.id}", member_role: %{role_id: ctx.low_role.id})
    |> render_submit()

    assert Repo.get_by(MemberRole, user_id: member.id, role_id: ctx.low_role.id)
    assert has_element?(view, "#member-role-#{member.id}-#{ctx.low_role.id}")

    view |> element("#remove-member-role-#{member.id}-#{ctx.low_role.id}") |> render_click()

    refute Repo.get_by(MemberRole, user_id: member.id, role_id: ctx.low_role.id)
    refute has_element?(view, "#member-role-#{member.id}-#{ctx.low_role.id}")
  end

  test "a refused action shows a flash and changes nothing", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.manager), ~p"/settings?tab=roles")

    refute has_element?(view, "#move-role-up-#{ctx.manager_role.id}")
    render_click(view, "delete_role", %{"id" => ctx.manager_role.id})

    assert has_element?(view, "#flash-error")
    assert Repo.get(Role, ctx.manager_role.id)
  end

  test "another manager's change refreshes an open roles tab", %{conn: conn} = ctx do
    {:ok, view, _html} = live(log_in_as(conn, ctx.manager), ~p"/settings?tab=roles")

    {:ok, role} =
      Tavern.Chat.create_role(%Tavern.Accounts.Scope{user_id: ctx.manager.id}, %{
        "name" => "Elsewhere"
      })

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#role-row-#{role.id}")
  end

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end
end
