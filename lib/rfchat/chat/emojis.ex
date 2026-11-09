defmodule Rfchat.Chat.Emojis do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.Emoji
  alias Rfchat.Chat.MediaAsset
  alias Rfchat.Chat.MediaAssets
  alias Rfchat.Chat.Visibility
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  def list_custom_emojis do
    Emoji
    |> order_by([emoji], asc: emoji.name, asc: emoji.inserted_at)
    |> preload([:asset, :creator, :emoji_roles])
    |> Repo.all()
  end

  def list_available_emojis(%User{} = user) do
    user = Repo.preload(user, member_roles: :role)
    role_ids = role_ids(user)
    manager? = can_manage_emojis?(user)

    list_custom_emojis()
    |> Enum.filter(&emoji_available?(&1, role_ids, manager?))
  end

  def get_emoji!(id) do
    Emoji
    |> preload([:asset, :creator, :emoji_roles])
    |> Repo.get!(id)
  end

  def change_emoji(%Emoji{} = emoji, attrs \\ %{}) do
    Emoji.changeset(emoji, attrs)
  end

  def create_custom_emoji_from_upload(attrs, %User{} = creator, upload) when is_map(attrs) do
    attrs = normalize_emoji_attrs(attrs)

    Repo.transaction(fn ->
      with {:ok, asset} <- MediaAssets.create_media_asset_from_upload(upload, creator),
           {:ok, emoji} <-
             %Emoji{creator_id: creator.id}
             |> Emoji.changeset(Map.put(attrs, "asset_id", asset.id))
             |> Repo.insert() do
        Repo.preload(emoji, [:asset, :creator, :emoji_roles])
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {:error, reason, :upload} -> Repo.rollback({:upload, reason})
      end
    end)
    |> case do
      {:ok, emoji} -> {:ok, emoji}
      {:error, {:upload, reason}} -> {:error, reason}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def delete_custom_emoji(%Emoji{} = emoji) do
    emoji = Repo.preload(emoji, [:asset])

    Repo.transaction(fn ->
      {:ok, deleted_emoji} = Repo.delete(emoji)

      case deleted_emoji.asset do
        %MediaAsset{} = asset ->
          MediaAssets.delete_media_asset(asset)

        _ ->
          {:ok, nil}
      end

      deleted_emoji
    end)
    |> case do
      {:ok, deleted_emoji} -> {:ok, deleted_emoji}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_available_emoji_for_user(emoji_id, %User{} = user) do
    emoji = get_emoji!(emoji_id)
    user = Repo.preload(user, member_roles: :role)

    if emoji_available?(emoji, role_ids(user), can_manage_emojis?(user)) do
      {:ok, emoji}
    else
      {:error, :forbidden}
    end
  rescue
    Ecto.NoResultsError -> {:error, :invalid_emoji}
  end

  # `manager?` is the user's manage_emojis_and_stickers decision, made once by the caller so a
  # list does not decide it per emoji.
  defp emoji_available?(%Emoji{} = emoji, role_ids, manager?) do
    cond do
      not emoji.available -> false
      manager? -> true
      emoji.emoji_roles == [] -> emoji.listed
      true -> emoji.listed and Enum.any?(emoji.emoji_roles, &MapSet.member?(role_ids, &1.role_id))
    end
  end

  defp can_manage_emojis?(%User{id: user_id}),
    do: Visibility.can?(%Scope{user_id: user_id}, :manage_emojis_and_stickers, :server)

  defp role_ids(%User{} = user) do
    MapSet.new(Enum.map(user.member_roles || [], & &1.role_id))
  end

  defp normalize_emoji_attrs(attrs) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    name = String.trim(Map.get(attrs, "name", ""))
    shortcode = Map.get(attrs, "shortcode") |> blank_to_nil() |> normalize_shortcode(name)

    attrs
    |> Map.put("name", name)
    |> Map.put("shortcode", shortcode)
    |> Map.put_new("requires_colons", true)
    |> Map.put_new("available", true)
    |> Map.put_new("listed", true)
  end

  defp normalize_shortcode(nil, name), do: normalize_shortcode(name, name)

  defp normalize_shortcode(value, _name) when is_binary(value) do
    normalized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_+-]+/u, "_")
      |> String.trim("_:")

    if normalized == "", do: nil, else: ":#{normalized}:"
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
