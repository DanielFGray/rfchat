defmodule TavernWeb.Plugs.RequireBotAuth do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias Tavern.Bots

  def init(opts), do: opts

  def call(conn, _opts) do
    with [authorization] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- authorization,
         {:ok, bot_scope} <- Bots.get_bot_scope_by_token(token) do
      assign(conn, :current_bot_scope, bot_scope)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Valid bot bearer token required."}})
        |> halt()
    end
  end
end
