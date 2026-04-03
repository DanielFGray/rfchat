defmodule RfchatWeb.Plugs.RequireBotAuth do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias Rfchat.Bots

  def init(opts), do: opts

  def call(conn, _opts) do
    with [authorization] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- authorization,
         {:ok, bot_scope} <- Bots.get_bot_scope_by_token(token) do
      conn
      |> assign(:current_bot_scope, bot_scope)
      |> assign(:current_bot_user, bot_scope.bot_user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Valid bot bearer token required."}})
        |> halt()
    end
  end
end
