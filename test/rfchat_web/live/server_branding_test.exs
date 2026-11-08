defmodule RfchatWeb.ServerBrandingTest do
  use RfchatWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Rfchat.ChatFixtures
  import RfchatWeb.GuildLiveFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.ServerSettings
  alias Rfchat.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    :ok
  end

  test "a member without manage_server sees no branding form and forged events change nothing",
       %{conn: conn} do
    {:ok, _} = Chat.update_server_settings(%{"name" => "Original"}, owner())
    conn = log_in_member_user(conn, "branding")
    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    refute has_element?(view, "#server-branding")
    refute has_element?(view, "#server-settings-form")

    render_hook(view, "save_server_settings", %{"server_settings" => %{"name" => "Hijacked"}})
    assert has_element?(view, "#flash-error", "You cannot change server branding.")

    render_hook(view, "remove_server_icon", %{})
    assert has_element?(view, "#flash-error", "You cannot change server branding.")

    assert %ServerSettings{name: "Original"} = Repo.one(ServerSettings)
  end

  test "a role with manage_server can rename the server", %{conn: conn} do
    _owner = owner()
    conn = log_in_member_user(conn, "brand_manager")
    member = current_user_from_conn(conn)
    role = role_fixture(%{permissions: PermissionBits.combine([:manage_server])})
    member_role_fixture(member, role)

    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    view
    |> form("#server-settings-form", %{server_settings: %{name: "Managed HQ"}})
    |> render_submit()

    assert %ServerSettings{name: "Managed HQ"} = Repo.one(ServerSettings)
  end

  test "a demoted owner's stale struct cannot change branding" do
    owner = owner()
    second_owner = user_fixture()
    {:ok, _} = Rfchat.Accounts.promote_to_owner(owner, second_owner)
    stale_second_owner = Rfchat.Accounts.get_user_with_membership!(second_owner.id)
    {:ok, _} = Rfchat.Accounts.demote_from_owner(owner, second_owner)

    assert {:error, :forbidden} =
             Chat.update_server_settings(%{"name" => "Stale"}, stale_second_owner)
  end

  # The first registered user becomes the owner.
  defp owner do
    case Repo.one(from(m in Rfchat.Chat.Membership, where: m.is_owner, limit: 1, preload: :user)) do
      nil -> user_fixture()
      membership -> Rfchat.Accounts.get_user_with_membership!(membership.user_id)
    end
  end
end
