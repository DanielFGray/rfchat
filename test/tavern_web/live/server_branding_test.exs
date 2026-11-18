defmodule TavernWeb.ServerBrandingTest do
  use TavernWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tavern.ChatFixtures
  import TavernWeb.ServerLiveFixtures

  alias Tavern.Bootstrap
  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.ServerSettings
  alias Tavern.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    :ok
  end

  test "a member without manage_server sees no branding form and forged events change nothing",
       %{conn: conn} do
    {:ok, _} = Chat.update_server_settings(%{"name" => "Original"}, owner_fixture())
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
    _owner = owner_fixture()
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
    owner = owner_fixture()
    second_owner = user_fixture()
    {:ok, _} = Tavern.Accounts.promote_to_owner(scope_for(owner), second_owner.id)
    stale_second_owner = user_with_membership!(second_owner.id)
    {:ok, _} = Tavern.Accounts.demote_from_owner(scope_for(owner), second_owner.id)

    assert {:error, :forbidden} =
             Chat.update_server_settings(%{"name" => "Stale"}, stale_second_owner)
  end

  test "forged icon_asset_id in save_server_settings does not change the icon", %{conn: conn} do
    owner = owner_fixture()
    emoji = emoji_fixture(owner)
    {:ok, _} = Chat.update_server_settings(%{"name" => "Brand HQ"}, owner)

    conn = log_in_owner_user(conn)
    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    render_hook(view, "save_server_settings", %{
      "server_settings" => %{"name" => "Brand HQ", "icon_asset_id" => emoji.asset_id}
    })

    settings = Repo.one(ServerSettings)
    assert settings.name == "Brand HQ"
    assert is_nil(settings.icon_asset_id)
    assert Repo.get(Tavern.Chat.MediaAsset, emoji.asset_id)
  end

  test "remove_server_icon clears a real server icon through the LiveView", %{conn: conn} do
    owner = owner_fixture()

    path =
      Path.join(System.tmp_dir!(), "tavern-brand-icon-#{System.unique_integer([:positive])}.png")

    File.write!(path, "fake png bytes")

    assert {:ok, settings} =
             Chat.update_server_settings(
               %{
                 "name" => "Brand HQ",
                 "icon_upload" => %{
                   path: path,
                   client_name: "brand.png",
                   client_type: "image/png"
                 }
               },
               owner
             )

    File.rm(path)
    icon_id = settings.icon_asset_id

    conn = log_in_owner_user(conn)
    {:ok, view, _html} = live(conn, ~p"/settings?tab=server")

    view |> element("#remove-server-icon") |> render_click()

    assert has_element?(view, "#flash-info", "Server icon removed.")
    assert %ServerSettings{icon_asset_id: nil} = Repo.one(ServerSettings)
    assert is_nil(Repo.get(Tavern.Chat.MediaAsset, icon_id))
  end
end
