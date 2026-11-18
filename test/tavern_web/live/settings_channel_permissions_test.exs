defmodule TavernWeb.SettingsChannelPermissionsTest do
  use TavernWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.GuildLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.ChannelPermissionOverwrite
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Role
  alias Tavern.Chat.User
  alias Tavern.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    channel = channel_fixture(%{name: "Lounge"})

    manager_role =
      role_fixture(%{
        name: "Manager",
        position: 50,
        permissions: bits([:view_channel, :send_messages, :manage_channels, :manage_roles])
      })

    low_role = role_fixture(%{name: "Low", position: 10})
    manager = user_fixture()
    member_role_fixture(manager, manager_role)

    %{
      owner: owner,
      channel: channel,
      manager: manager,
      low_role: low_role,
      everyone: Chat.default_role()
    }
  end

  defp bits(names), do: PermissionBits.combine(names)

  defp key(kind, id), do: "#{kind}-#{id}"

  defp log_in_as(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, Tavern.Accounts.generate_user_session_token(user))
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{user.id}")
  end

  defp open_channel_editor(conn, user, channel) do
    {:ok, view, _html} = live(log_in_as(conn, user), ~p"/settings")
    view |> element("#edit-channel-#{channel.slug}") |> render_click()
    view
  end

  defp stored(channel, role_id) do
    Repo.get_by(ChannelPermissionOverwrite, channel_id: channel.id, role_id: role_id)
  end

  test "the owner denies @everyone a channel from the editor", %{conn: conn} = ctx do
    view = open_channel_editor(conn, ctx.owner, ctx.channel)
    everyone = key(:role, ctx.everyone.id)

    assert has_element?(view, "#overwrite-row-#{everyone}")
    view |> element("#toggle-overwrite-#{everyone}") |> render_click()

    view
    |> form("#overwrite-form-#{everyone}", overwrite: %{bits: %{view_channel: "deny"}})
    |> render_submit()

    assert stored(ctx.channel, ctx.everyone.id).deny_permissions == bits([:view_channel])
    assert has_element?(view, "#overwrite-#{everyone}-view_channel-deny[checked]")
    assert render(view) =~ "Permissions saved."
  end

  test "a manager's save keeps stored bits it may not change", %{conn: conn} = ctx do
    {:ok, _} =
      Chat.put_overwrite(
        scope_for(ctx.owner),
        ctx.channel.id,
        {:role, ctx.low_role.id},
        bits([:manage_messages]),
        0
      )

    view = open_channel_editor(conn, ctx.manager, ctx.channel)
    low = key(:role, ctx.low_role.id)
    view |> element("#toggle-overwrite-#{low}") |> render_click()

    assert has_element?(view, "#overwrite-#{low}-manage_messages-allow[disabled]")
    refute has_element?(view, "#overwrite-#{low}-send_messages-allow[disabled]")

    view
    |> form("#overwrite-form-#{low}", overwrite: %{bits: %{send_messages: "allow"}})
    |> render_submit()

    assert stored(ctx.channel, ctx.low_role.id).allow_permissions ==
             bits([:manage_messages, :send_messages])
  end

  test "a manager adds and removes a role override", %{conn: conn} = ctx do
    view = open_channel_editor(conn, ctx.manager, ctx.channel)
    low = key(:role, ctx.low_role.id)
    refute has_element?(view, "#overwrite-row-#{low}")

    view
    |> form("#add-overwrite-role-form", overwrite_role: %{target: "role:#{ctx.low_role.id}"})
    |> render_submit()

    assert has_element?(view, "#overwrite-row-#{low}")
    assert stored(ctx.channel, ctx.low_role.id)

    view |> element("#delete-overwrite-#{low}") |> render_click()

    refute has_element?(view, "#overwrite-row-#{low}")
    refute stored(ctx.channel, ctx.low_role.id)
  end

  test "a manager adds a member override", %{conn: conn} = ctx do
    member = user_fixture()
    view = open_channel_editor(conn, ctx.manager, ctx.channel)

    view
    |> form("#add-overwrite-member-form", overwrite_member: %{target: "user:#{member.id}"})
    |> render_submit()

    assert has_element?(view, "#overwrite-row-#{key(:user, member.id)}")
  end

  test "a role above the manager is locked and not offered", %{conn: conn} = ctx do
    high = role_fixture(%{name: "High", position: 80})
    {:ok, _} = Chat.put_overwrite(scope_for(ctx.owner), ctx.channel.id, {:role, high.id}, 0, 0)

    view = open_channel_editor(conn, ctx.manager, ctx.channel)
    row = key(:role, high.id)
    view |> element("#toggle-overwrite-#{row}") |> render_click()

    assert has_element?(view, "#overwrite-#{row}-send_messages-allow[disabled]")
    refute has_element?(view, "#save-overwrite-#{row}")
    refute has_element?(view, "#delete-overwrite-#{row}")
    refute has_element?(view, "#add-overwrite-role option[value='role:#{high.id}']")
  end

  test "a refused save becomes a flash", %{conn: conn} = ctx do
    view = open_channel_editor(conn, ctx.manager, ctx.channel)
    everyone = key(:role, ctx.everyone.id)
    low = key(:role, ctx.low_role.id)

    view
    |> form("#add-overwrite-role-form", overwrite_role: %{target: "role:#{ctx.low_role.id}"})
    |> render_submit()

    assert has_element?(view, "#overwrite-form-#{low}")

    # The role moves above the manager after the form was drawn.
    Repo.update_all(from(role in Role, where: role.id == ^ctx.low_role.id), set: [position: 90])

    html =
      view
      |> form("#overwrite-form-#{low}", overwrite: %{bits: %{send_messages: "allow"}})
      |> render_submit()

    assert html =~ "You do not have permission to do that."
    assert stored(ctx.channel, ctx.low_role.id).allow_permissions == 0
    assert has_element?(view, "#overwrite-row-#{everyone}")
  end

  test "a channel manager without manage_roles sees no Permissions section",
       %{conn: conn} = ctx do
    view = open_channel_editor(conn, channel_manager_fixture(), ctx.channel)

    assert has_element?(view, "#channel-form")
    refute has_element?(view, "#channel-permissions")
  end

  test "an override saved elsewhere hides the channel from an open sidebar",
       %{conn: conn} = ctx do
    conn = log_in_member_user(conn, "overwrites")
    member = Repo.get_by!(User, email: "guildlive-overwrites@example.com")
    {:ok, view, _html} = live_hydrated(conn, ~p"/")
    assert has_element?(view, "#channel-link-#{ctx.channel.slug}")

    {:ok, _} =
      Chat.put_overwrite(
        scope_for(ctx.owner),
        ctx.channel.id,
        {:user, member.id},
        0,
        bits([:view_channel])
      )

    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#channel-link-#{ctx.channel.slug}")
  end
end
