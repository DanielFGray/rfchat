defmodule TavernWeb.ServerLiveRolesTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.User
  alias Tavern.Repo

  test "a role given elsewhere shows the channel it unlocks in an open sidebar", %{conn: conn} do
    Bootstrap.ensure_seed_data!()
    owner = owner_fixture()
    hidden = channel_fixture(%{name: "Insiders", slug: unique_slug(), position: 20})

    channel_permission_overwrite_fixture(hidden, %{
      role_id: Chat.default_role().id,
      deny_permissions: PermissionBits.combine([:view_channel])
    })

    insiders = role_fixture(%{name: "Insiders", position: 5})

    channel_permission_overwrite_fixture(hidden, %{
      role_id: insiders.id,
      allow_permissions: PermissionBits.combine([:view_channel])
    })

    conn = log_in_member_user(conn, "roles")
    member = Repo.get_by!(User, email: "serverlive-roles@example.com")
    {:ok, view, _html} = live_hydrated(conn, ~p"/")
    refute has_element?(view, "#channel-link-#{hidden.slug}")

    assert {:ok, _role} = Chat.add_member_role(scope_for(owner), member.id, insiders.id)

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#channel-link-#{hidden.slug}")
  end
end
