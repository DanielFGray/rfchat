defmodule RfchatWeb.UploadController do
  @moduledoc """
  Serves uploaded files from the object store. The store's endpoint is internal to the
  platform, so browsers fetch uploads through the app.
  """
  use RfchatWeb, :controller

  alias Rfchat.Chat.MediaAssets

  # Each storage key holds a fresh UUID and is never rewritten, so a response never goes stale.
  @cache_control "public, max-age=31536000, immutable"

  # Every upload is an image. If a browser renders one as a document anyway, it runs no script
  # and loads nothing.
  @content_security_policy "default-src 'none'; sandbox"

  def show(conn, %{"key" => segments}) do
    case MediaAssets.fetch_upload(Enum.join(segments, "/")) do
      {:ok, body, content_type} ->
        conn
        |> put_resp_content_type(content_type || "application/octet-stream", nil)
        |> put_resp_header("cache-control", @cache_control)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", @content_security_policy)
        |> send_resp(200, body)

      {:error, :not_found} ->
        send_resp(conn, 404, "not found")

      {:error, _reason} ->
        send_resp(conn, 502, "upload unavailable")
    end
  end
end
