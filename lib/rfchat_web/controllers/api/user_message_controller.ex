defmodule RfchatWeb.API.UserMessageController do
  @moduledoc """
  Thin HTTP endpoint for session-authenticated users to post messages.
  Primarily used by load tests (k6) to stress the message creation path
  without requiring a LiveView WebSocket connection.
  """

  use RfchatWeb, :controller

  alias Rfchat.Bots.Params
  alias Rfchat.Chat
  alias RfchatWeb.API.ErrorHelpers

  def create(conn, %{"channel_id" => channel_id, "message" => message_params})
      when is_map(message_params) do
    user = conn.assigns.current_user

    case Params.fetch_channel(channel_id) do
      {:error, _} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Channel not found.")

      {:ok, channel} ->
        case Chat.create_message(channel, user, message_params, preload: false) do
          {:ok, message} ->
            conn
            |> put_status(:created)
            |> json(%{data: %{id: message.id, channel_id: message.channel_id}})

          {:error, :forbidden} ->
            ErrorHelpers.render_error(
              conn,
              :forbidden,
              "forbidden",
              "You cannot send messages to that channel."
            )

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

  def create(conn, _params), do: ErrorHelpers.render_invalid_body(conn)
end
