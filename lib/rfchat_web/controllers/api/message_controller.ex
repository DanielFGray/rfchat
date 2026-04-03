defmodule RfchatWeb.API.MessageController do
  use RfchatWeb, :controller

  alias Rfchat.Bots
  alias RfchatWeb.API.ErrorHelpers

  def index(conn, %{"channel_id" => channel_id} = params) do
    command_params = %{"channel_id" => channel_id, "limit" => Map.get(params, "limit")}

    case Bots.command_list_messages(conn.assigns.current_bot_scope, command_params) do
      {:ok, %{messages: messages}} ->
        render(conn, :index, messages: messages)

      {:error, :forbidden} ->
        ErrorHelpers.render_error(conn, :forbidden, "forbidden", "Bot cannot read that channel.")

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Channel not found.")

      {:error, _} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_params",
          "Invalid message query."
        )
    end
  end

  def create(conn, %{"channel_id" => channel_id, "message" => message_params}) do
    params = Map.put(message_params, "channel_id", channel_id)

    case Bots.command_send_message(conn.assigns.current_bot_scope, params) do
      {:ok, %{message: message}} ->
        conn
        |> put_status(:created)
        |> render(:show, message: message)

      {:error, :forbidden} ->
        ErrorHelpers.render_error(
          conn,
          :forbidden,
          "forbidden",
          "Bot cannot send to that channel."
        )

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Channel not found.")

      {:error, %Ecto.Changeset{} = changeset} ->
        ErrorHelpers.render_changeset_error(
          conn,
          :unprocessable_entity,
          "invalid_message",
          changeset
        )

      {:error, reason} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_message",
          to_string(reason)
        )
    end
  end
end
