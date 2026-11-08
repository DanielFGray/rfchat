defmodule Rfchat.Chat.MediaAssets do
  @moduledoc """
  Uploaded images. Each asset's bytes live in `Rfchat.ObjectStore` under its `storage_key`,
  and the app serves them at `asset_url/1`.
  """

  alias Rfchat.Chat.MediaAsset
  alias Rfchat.Chat.User
  alias Rfchat.ObjectStore
  alias Rfchat.Repo

  @emoji_upload_dir "emojis"
  @server_icon_upload_dir "server_icons"
  @allowed_upload_content_types ~w(image/png image/jpeg image/gif image/webp)

  def asset_url(%MediaAsset{storage_key: storage_key}) when is_binary(storage_key),
    do: "/uploads/#{storage_key}"

  @doc """
  The bytes and recorded content type of the asset stored at `storage_key`, as
  `{:ok, body, content_type}`. A key with no asset row is `{:error, :not_found}` and never
  reaches the store, so a request can read only an object the app recorded, with the type the
  app checked when it stored it.
  """
  def fetch_upload(storage_key) when is_binary(storage_key) do
    case Repo.get_by(MediaAsset, storage_provider: "s3", storage_key: storage_key) do
      nil ->
        {:error, :not_found}

      %MediaAsset{content_type: content_type} ->
        with {:ok, body, _stored_type} <- ObjectStore.get(storage_key) do
          {:ok, body, content_type}
        end
    end
  end

  @doc """
  Stores the uploaded file in the object store, then records it. Returns
  `{:error, reason, :upload}` when the file is refused or cannot be stored.
  """
  def create_media_asset_from_upload(
        %{path: path, client_name: client_name, client_type: client_type},
        %User{} = creator,
        opts \\ []
      ) do
    allowed_types = Keyword.get(opts, :allowed_types, @allowed_upload_content_types)
    upload_dir = Keyword.get(opts, :upload_dir, @emoji_upload_dir)
    kind = Keyword.get(opts, :kind, :emoji)

    with :ok <- validate_upload_type(client_type, allowed_types),
         {:ok, body} <- File.read(path),
         storage_key =
           "#{upload_dir}/#{Ecto.UUID.generate()}#{upload_extension(client_name, client_type)}",
         :ok <- ObjectStore.put(storage_key, body, client_type),
         {:ok, asset} <-
           %MediaAsset{}
           |> MediaAsset.changeset(%{
             uploader_id: creator.id,
             kind: kind,
             storage_provider: "s3",
             storage_key: storage_key,
             original_filename: client_name,
             content_type: client_type,
             byte_size: byte_size(body),
             sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
           })
           |> Repo.insert() do
      {:ok, asset}
    else
      {:error, reason} -> {:error, reason, :upload}
    end
  end

  def create_server_icon_from_upload(%User{} = creator, upload) do
    create_media_asset_from_upload(upload, creator,
      allowed_types: @allowed_upload_content_types,
      upload_dir: @server_icon_upload_dir,
      kind: :server_icon
    )
  end

  def delete_media_asset(%MediaAsset{storage_key: storage_key} = asset) do
    with :ok <- ObjectStore.delete(storage_key) do
      Repo.delete(asset)
    end
  end

  defp validate_upload_type(content_type, allowed_types) do
    if content_type in allowed_types, do: :ok, else: {:error, :invalid_upload_type}
  end

  defp upload_extension(filename, content_type) do
    ext = filename |> Path.extname() |> String.downcase()

    if ext in ~w(.png .jpg .jpeg .gif .webp),
      do: ext,
      else: extension_for_content_type(content_type)
  end

  defp extension_for_content_type("image/png"), do: ".png"
  defp extension_for_content_type("image/jpeg"), do: ".jpg"
  defp extension_for_content_type("image/gif"), do: ".gif"
  defp extension_for_content_type("image/webp"), do: ".webp"
  defp extension_for_content_type(_), do: ".bin"
end
