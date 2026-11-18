defmodule TavernWeb.UploadControllerTest do
  use TavernWeb.ConnCase, async: false

  import Tavern.ChatFixtures

  alias Tavern.Chat.MediaAsset
  alias Tavern.ObjectStore
  alias Tavern.Repo

  test "serves a recorded asset with its recorded type and a long cache lifetime", %{conn: conn} do
    key = "emojis/#{Ecto.UUID.generate()}.png"
    # The store's own type differs, to show the response uses the type the app recorded.
    :ok = ObjectStore.put(key, "png bytes", "text/html")
    record_asset!(key, "image/png")

    conn = get(conn, "/uploads/#{key}")

    assert response(conn, 200) == "png bytes"
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
  end

  test "answers 404 for an object in the bucket that no asset records", %{conn: conn} do
    key = "emojis/#{Ecto.UUID.generate()}.png"
    :ok = ObjectStore.put(key, "unrecorded", "image/png")

    assert conn |> get("/uploads/#{key}") |> response(404)
  end

  test "answers 404 for the bucket root and for dot segments", %{conn: conn} do
    assert conn |> get("/uploads") |> response(404)
    assert build_conn() |> get("/uploads/%2E%2E") |> response(404)
  end

  test "answers 404 for a recorded asset the bucket does not hold", %{conn: conn} do
    key = "emojis/#{Ecto.UUID.generate()}.png"
    record_asset!(key, "image/png")

    assert conn |> get("/uploads/#{key}") |> response(404)
  end

  defp record_asset!(key, content_type) do
    %MediaAsset{}
    |> MediaAsset.changeset(%{
      uploader_id: user_fixture().id,
      kind: :emoji,
      storage_provider: "s3",
      storage_key: key,
      content_type: content_type,
      byte_size: 9
    })
    |> Repo.insert!()
  end
end
