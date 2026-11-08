defmodule RfchatWeb.UploadControllerTest do
  use RfchatWeb.ConnCase, async: false

  alias Rfchat.ObjectStore

  test "serves a stored object with its type and a long cache lifetime", %{conn: conn} do
    key = "emojis/#{Ecto.UUID.generate()}.png"
    :ok = ObjectStore.put(key, "png bytes", "image/png")

    conn = get(conn, "/uploads/#{key}")

    assert response(conn, 200) == "png bytes"
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "answers 404 for a key the bucket does not hold", %{conn: conn} do
    assert conn |> get("/uploads/emojis/#{Ecto.UUID.generate()}.png") |> response(404)
  end
end
