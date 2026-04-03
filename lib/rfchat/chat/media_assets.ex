defmodule Rfchat.Chat.MediaAssets do
  @moduledoc false

  alias Rfchat.Chat.MediaAsset
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  @emoji_upload_dir "uploads/emojis"
  @server_icon_upload_dir "uploads/server_icons"
  @allowed_upload_content_types ~w(image/png image/jpeg image/gif image/webp)

  def asset_url(%MediaAsset{storage_key: storage_key}) when is_binary(storage_key),
    do: "/#{storage_key}"

  def create_media_asset_from_upload(
        %{path: path, client_name: client_name, client_type: client_type},
        %User{} = creator,
        opts \\ []
      ) do
    allowed_types = Keyword.get(opts, :allowed_types, @allowed_upload_content_types)
    upload_dir = Keyword.get(opts, :upload_dir, @emoji_upload_dir)
    kind = Keyword.get(opts, :kind, :emoji)

    with :ok <- validate_upload_type(client_type, allowed_types),
         {:ok, %{size: byte_size}} <- File.stat(path),
         ext <- upload_extension(client_name, client_type),
         storage_key <- Path.join(upload_dir, "#{Ecto.UUID.generate()}#{ext}"),
         destination <- asset_destination_path(storage_key),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(path, destination),
         {:ok, sha256} <- file_sha256(destination),
         {:ok, asset} <-
           %MediaAsset{}
           |> MediaAsset.changeset(%{
             uploader_id: creator.id,
             kind: kind,
             storage_key: storage_key,
             original_filename: client_name,
             content_type: client_type,
             byte_size: byte_size,
             sha256: sha256
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

  def delete_media_asset(%MediaAsset{} = asset) do
    maybe_delete_asset_file(asset)
    Repo.delete(asset)
  end

  defp validate_upload_type(content_type, allowed_types) do
    if content_type in allowed_types, do: :ok, else: {:error, :invalid_upload_type}
  end

  defp upload_extension(filename, content_type) do
    ext = filename |> Path.extname() |> String.downcase()

    case ext do
      ".png" -> ext
      ".jpg" -> ext
      ".jpeg" -> ext
      ".gif" -> ext
      ".webp" -> ext
      _ -> extension_for_content_type(content_type)
    end
  end

  defp extension_for_content_type("image/png"), do: ".png"
  defp extension_for_content_type("image/jpeg"), do: ".jpg"
  defp extension_for_content_type("image/gif"), do: ".gif"
  defp extension_for_content_type("image/webp"), do: ".webp"
  defp extension_for_content_type(_), do: ".bin"

  defp asset_destination_path(storage_key) do
    Application.app_dir(:rfchat, Path.join(["priv", "static", storage_key]))
  end

  defp file_sha256(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_delete_asset_file(%MediaAsset{storage_key: storage_key})
       when is_binary(storage_key) do
    storage_key
    |> asset_destination_path()
    |> File.rm()

    :ok
  end
end
