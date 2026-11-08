defmodule RfchatWeb.HealthControllerTest do
  use RfchatWeb.ConnCase, async: true

  test "GET /health answers 200 without a session", %{conn: conn} do
    assert conn |> get(~p"/health") |> response(200) == "ok"
  end
end
