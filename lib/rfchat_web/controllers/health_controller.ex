defmodule RfchatWeb.HealthController do
  use RfchatWeb, :controller

  require Logger

  # The platform polls this route, so a stalled database must fail the probe
  # within a few seconds rather than hold the connection open.
  @database_timeout 2_000

  @doc """
  The platform health check, `GET /healthz`. It answers 503 when the database
  cannot answer `SELECT 1`. Valkey is not checked: the chat still serves without it.
  """
  def show(conn, _params) do
    commit = Application.get_env(:rfchat, :git_commit) || "unknown"
    {status, body} = response(database_check(), commit)

    conn
    |> put_status(status)
    |> json(body)
  end

  @doc "Maps a dependency check result to the HTTP status and JSON body the platform contract requires."
  def response(:ok, commit), do: {200, %{status: "ok", commit: commit}}

  def response({:error, _reason}, commit),
    do: {503, %{status: "error", commit: commit, failed: ["database"]}}

  defp database_check do
    case Rfchat.Repo.query("SELECT 1", [], timeout: @database_timeout) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("health check: database failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    # Checkout failures raise rather than return, so they are mapped here.
    error in DBConnection.ConnectionError ->
      Logger.error("health check: database failed: #{inspect(error)}")
      {:error, error}
  end
end
