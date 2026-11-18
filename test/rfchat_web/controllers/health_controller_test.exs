defmodule RfchatWeb.HealthControllerTest do
  use RfchatWeb.ConnCase, async: false

  alias RfchatWeb.HealthController

  test "GET /healthz answers 200 without a session and names the deploy's commit", %{conn: conn} do
    previous = Application.get_env(:rfchat, :git_commit)
    Application.put_env(:rfchat, :git_commit, "36e28f1")
    on_exit(fn -> Application.put_env(:rfchat, :git_commit, previous) end)

    assert conn |> get(~p"/healthz") |> json_response(200) == %{
             "status" => "ok",
             "commit" => "36e28f1"
           }
  end

  describe "response/2" do
    test "a passing database check answers 200 with the commit" do
      assert HealthController.response(:ok, "36e28f1") ==
               {200, %{status: "ok", commit: "36e28f1"}}
    end

    test "a failing database check answers 503 and names only the dependency" do
      assert HealthController.response({:error, :timeout}, "unknown") ==
               {503, %{status: "error", commit: "unknown", failed: ["database"]}}
    end
  end
end
