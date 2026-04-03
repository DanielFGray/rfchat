defmodule Rfchat.Chat.ServerConfig do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Chat.MediaAsset
  alias Rfchat.Chat.MediaAssets
  alias Rfchat.Chat.ServerSettings
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  def get_server_settings do
    ServerSettings
    |> preload([:icon_asset])
    |> Repo.one()
    |> case do
      nil -> %ServerSettings{name: default_server_name(), singleton: true}
      settings -> settings
    end
  end

  def change_server_settings(%ServerSettings{} = server_settings, attrs \\ %{}) do
    ServerSettings.changeset(server_settings, attrs)
  end

  def update_server_settings(attrs, %User{} = actor) when is_map(attrs) do
    server_settings =
      ServerSettings
      |> preload([:icon_asset])
      |> Repo.one()
      |> case do
        nil -> %ServerSettings{}
        settings -> settings
      end

    attrs = Map.put_new(attrs, "name", default_server_name())

    Repo.transaction(fn ->
      previous_icon_asset = server_settings.icon_asset

      with {:ok, icon_asset_id, _icon_asset} <- maybe_persist_server_icon(attrs, actor),
           attrs <- persistable_server_settings_attrs(attrs, icon_asset_id),
           {:ok, settings} <-
             server_settings
             |> ServerSettings.changeset(attrs)
             |> Repo.insert_or_update() do
        settings = Repo.preload(settings, [:icon_asset])

        if not is_nil(previous_icon_asset) and icon_asset_id != :keep and
             previous_icon_asset.id != icon_asset_id do
          MediaAssets.delete_media_asset(previous_icon_asset)
        end

        settings
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {:error, reason, :upload} -> Repo.rollback({:upload, reason})
      end
    end)
    |> case do
      {:ok, settings} -> {:ok, settings}
      {:error, {:upload, reason}} -> {:error, reason}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def server_icon_url(%ServerSettings{icon_asset: %MediaAsset{} = asset}),
    do: MediaAssets.asset_url(asset)

  def server_icon_url(%ServerSettings{icon_asset: %Ecto.Association.NotLoaded{}}), do: nil
  def server_icon_url(_settings), do: nil

  def default_server_name do
    Application.get_env(:rfchat, :guild_name, "RFChat")
  end

  defp maybe_persist_server_icon(attrs, actor) do
    case Map.get(attrs, "icon_upload") do
      nil ->
        if Map.has_key?(attrs, "icon_asset_id") do
          {:ok, blank_to_nil(Map.get(attrs, "icon_asset_id")), nil}
        else
          {:ok, :keep, nil}
        end

      upload ->
        case MediaAssets.create_server_icon_from_upload(actor, upload) do
          {:ok, asset} -> {:ok, asset.id, asset}
          {:error, reason, :upload} -> {:error, reason, :upload}
          {:error, reason} -> {:error, reason, :upload}
        end
    end
  end

  defp persistable_server_settings_attrs(attrs, icon_asset_id) do
    attrs =
      attrs
      |> Map.take(["name"])
      |> Map.put("singleton", true)

    if icon_asset_id == :keep do
      attrs
    else
      Map.put(attrs, "icon_asset_id", blank_to_nil(icon_asset_id))
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
