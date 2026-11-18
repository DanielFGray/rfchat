defmodule Tavern.Chat.ServerConfig do
  @moduledoc false

  import Ecto.Changeset, only: [put_change: 3]
  import Ecto.Query, warn: false

  @cache_key {__MODULE__, :server_settings}

  alias Tavern.Accounts.Scope
  alias Tavern.Chat.MediaAsset
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.ServerSettings
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  def get_server_settings do
    case :persistent_term.get(@cache_key, :missing) do
      :missing ->
        settings = load_server_settings()
        :persistent_term.put(@cache_key, settings)
        settings

      settings ->
        settings
    end
  end

  def change_server_settings(%ServerSettings{} = server_settings, attrs \\ %{}) do
    ServerSettings.changeset(server_settings, attrs)
  end

  @doc """
  Changes the server name, and replaces the icon when attrs hold an `"icon_upload"`.
  The actor must hold `manage_server` now, in the database; the check runs before an
  uploaded icon is written to disk. An `"icon_asset_id"` in attrs is ignored.
  """
  def update_server_settings(attrs, %User{} = actor) when is_map(attrs) do
    if manages_server?(actor),
      do: persist_server_settings(attrs, actor),
      else: {:error, :forbidden}
  end

  @doc """
  Clears the server icon. Deletes the previous asset only when its kind is `:server_icon`.
  """
  def remove_server_icon(%User{} = actor) do
    if manages_server?(actor), do: persist_remove_server_icon(), else: {:error, :forbidden}
  end

  defp manages_server?(%User{id: user_id}),
    do: Visibility.can?(%Scope{user_id: user_id}, :manage_server, :server)

  def server_icon_url(%ServerSettings{icon_asset: %MediaAsset{} = asset}),
    do: MediaAssets.asset_url(asset)

  def server_icon_url(%ServerSettings{icon_asset: %Ecto.Association.NotLoaded{}}), do: nil
  def server_icon_url(_settings), do: nil

  def default_server_name do
    Application.get_env(:tavern, :server_name, "Tavern")
  end

  defp persist_server_settings(attrs, actor) do
    name_attrs = name_attrs(attrs)

    Repo.transaction(fn ->
      server_settings = lock_server_settings()
      previous_icon_asset = server_settings.icon_asset

      with {:ok, icon_change} <- resolve_icon_change(attrs, actor),
           {:ok, settings} <-
             server_settings
             |> settings_changeset(name_attrs, icon_change)
             |> Repo.insert_or_update() do
        settings = Repo.preload(settings, [:icon_asset], force: true)

        if icon_change != :keep do
          maybe_delete_server_icon_asset(previous_icon_asset)
        end

        settings
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {:error, reason, :upload} -> Repo.rollback({:upload, reason})
      end
    end)
    |> finalize_settings_write()
  end

  defp persist_remove_server_icon do
    Repo.transaction(fn ->
      server_settings = lock_server_settings()
      previous_icon_asset = server_settings.icon_asset

      with {:ok, settings} <-
             server_settings
             |> settings_changeset(name_attrs(%{"name" => server_settings.name}), {:replace, nil})
             |> Repo.insert_or_update() do
        maybe_delete_server_icon_asset(previous_icon_asset)
        Repo.preload(settings, [:icon_asset], force: true)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> finalize_settings_write()
  end

  defp finalize_settings_write(result) do
    case result do
      {:ok, settings} ->
        :persistent_term.put(@cache_key, settings)
        {:ok, settings}

      {:error, {:upload, reason}} ->
        {:error, reason}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp resolve_icon_change(attrs, actor) do
    case Map.get(attrs, "icon_upload") do
      nil ->
        {:ok, :keep}

      upload ->
        with {:ok, asset} <- MediaAssets.create_server_icon_from_upload(actor, upload) do
          {:ok, {:replace, asset.id}}
        end
    end
  end

  defp settings_changeset(server_settings, name_attrs, :keep) do
    server_settings
    |> ServerSettings.changeset(name_attrs)
    |> put_change(:singleton, true)
  end

  defp settings_changeset(server_settings, name_attrs, {:replace, icon_asset_id}) do
    server_settings
    |> ServerSettings.changeset(name_attrs)
    |> put_change(:singleton, true)
    |> put_change(:icon_asset_id, icon_asset_id)
  end

  # Only a purpose-built server icon may be deleted when the icon changes; an emoji or other
  # kind pointed here by an old write must stay so manage_emojis cannot be bypassed.
  defp maybe_delete_server_icon_asset(%MediaAsset{kind: :server_icon} = asset) do
    MediaAssets.delete_media_asset(asset)
  end

  defp maybe_delete_server_icon_asset(_asset), do: :ok

  defp name_attrs(attrs) do
    attrs
    |> Map.take(["name"])
    |> Map.put_new("name", default_server_name())
  end

  defp load_server_settings(query \\ ServerSettings) do
    case Repo.one(query) do
      nil -> %ServerSettings{name: default_server_name(), singleton: true, icon_asset: nil}
      settings -> Repo.preload(settings, [:icon_asset])
    end
  end

  # Writers read the previous icon under this lock, so two concurrent icon
  # changes never both delete the same old asset.
  defp lock_server_settings, do: load_server_settings(lock(ServerSettings, "FOR UPDATE"))
end
