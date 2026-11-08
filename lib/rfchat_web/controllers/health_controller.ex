defmodule RfchatWeb.HealthController do
  use RfchatWeb, :controller

  @doc "The platform's health check. It also names the running deploy's commit, or nil."
  def show(conn, _params) do
    json(conn, %{status: "ok", commit: Application.get_env(:rfchat, :git_commit)})
  end
end
