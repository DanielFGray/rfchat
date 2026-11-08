defmodule Rfchat.Chat.ServerConfigTest do
  use Rfchat.DataCase, async: false

  import Rfchat.ChatFixtures

  alias Rfchat.Bootstrap
  alias Rfchat.Chat.Emoji
  alias Rfchat.Chat.MediaAsset
  alias Rfchat.Chat.ServerConfig
  alias Rfchat.Chat.ServerSettings
  alias Rfchat.Repo

  setup do
    Bootstrap.ensure_seed_data!()
    :ok
  end

  test "update_server_settings ignores a client icon_asset_id pointing at an emoji asset" do
    owner = owner_fixture()
    emoji = emoji_fixture(owner)
    asset = emoji.asset

    assert {:ok, settings} =
             ServerConfig.update_server_settings(
               %{"name" => "HQ", "icon_asset_id" => asset.id},
               owner
             )

    assert settings.name == "HQ"
    assert is_nil(settings.icon_asset_id)
    assert Repo.get(MediaAsset, asset.id)
    assert Repo.get(Emoji, emoji.id)
  end

  test "a later icon upload does not delete an emoji that was never the icon" do
    owner = owner_fixture()
    emoji = emoji_fixture(owner)
    asset = emoji.asset

    assert {:ok, _} =
             ServerConfig.update_server_settings(
               %{"name" => "HQ", "icon_asset_id" => asset.id},
               owner
             )

    upload = icon_upload("first.png")

    assert {:ok, settings} =
             ServerConfig.update_server_settings(
               %{"name" => "HQ", "icon_upload" => upload},
               owner
             )

    File.rm(upload.path)

    assert settings.icon_asset.kind == :server_icon
    assert settings.icon_asset_id != asset.id
    assert Repo.get(MediaAsset, asset.id)
    assert Repo.get(Emoji, emoji.id)
  end

  test "remove_server_icon clears the icon and deletes the old server-icon asset" do
    owner = owner_fixture()
    upload = icon_upload("keep-then-remove.png")

    assert {:ok, settings} =
             ServerConfig.update_server_settings(
               %{"name" => "HQ", "icon_upload" => upload},
               owner
             )

    File.rm(upload.path)
    icon_id = settings.icon_asset_id

    assert {:ok, cleared} = ServerConfig.remove_server_icon(owner)

    assert is_nil(cleared.icon_asset_id)
    assert is_nil(Repo.get(MediaAsset, icon_id))
  end

  test "an upload replaces the icon and deletes the previous server-icon asset" do
    owner = owner_fixture()
    first = icon_upload("first.png")

    assert {:ok, settings} =
             ServerConfig.update_server_settings(
               %{"name" => "HQ", "icon_upload" => first},
               owner
             )

    File.rm(first.path)
    first_id = settings.icon_asset_id

    second = icon_upload("second.png")

    assert {:ok, replaced} =
             ServerConfig.update_server_settings(
               %{"name" => "HQ", "icon_upload" => second},
               owner
             )

    File.rm(second.path)

    assert replaced.icon_asset_id != first_id
    assert replaced.icon_asset.kind == :server_icon
    assert is_nil(Repo.get(MediaAsset, first_id))
    assert Repo.get(MediaAsset, replaced.icon_asset_id)
  end

  test "remove_server_icon leaves a non-server-icon asset in place when clearing the pointer" do
    owner = owner_fixture()
    emoji = emoji_fixture(owner)
    asset = emoji.asset

    settings =
      case Repo.one(from(s in ServerSettings, preload: [:icon_asset])) do
        nil -> %ServerSettings{name: "HQ", singleton: true}
        row -> row
      end

    {:ok, _} =
      settings
      |> Ecto.Changeset.change(%{icon_asset_id: asset.id, name: "HQ", singleton: true})
      |> Repo.insert_or_update()

    assert {:ok, cleared} = ServerConfig.remove_server_icon(owner)

    assert is_nil(cleared.icon_asset_id)
    assert Repo.get(MediaAsset, asset.id)
    assert Repo.get(Emoji, emoji.id)
  end

  defp icon_upload(filename) do
    path = Path.join(System.tmp_dir!(), "rfchat-icon-#{System.unique_integer([:positive])}.png")
    File.write!(path, "fake png bytes")
    %{path: path, client_name: filename, client_type: "image/png"}
  end
end
