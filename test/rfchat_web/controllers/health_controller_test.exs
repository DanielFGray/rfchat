defmodule RfchatWeb.HealthControllerTest do
  use RfchatWeb.ConnCase, async: false

  test "GET /health answers 200 without a session and names the deploy's commit", %{conn: conn} do
    previous = Application.get_env(:rfchat, :git_commit)
    Application.put_env(:rfchat, :git_commit, "36e28f1")
    on_exit(fn -> Application.put_env(:rfchat, :git_commit, previous) end)

    assert conn |> get(~p"/health") |> json_response(200) == %{
             "status" => "ok",
             "commit" => "36e28f1"
           }
  end
end
