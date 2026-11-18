defmodule TavernWeb.API.UserMessageController do
  @moduledoc """
  Thin HTTP endpoint for session-authenticated users to post messages.
  Primarily used by load tests (k6) to stress the message creation path
  without requiring a LiveView WebSocket connection.
  """

  use TavernWeb, :controller

  alias Tavern.Chat
  alias TavernWeb.API.ErrorHelpers

  def create(conn, %{"channel_id" => channel_id, "message" => message_params})
      when is_map(message_params) do
    case Chat.create_message(conn.assigns.current_scope, channel_id, message_params) do
      {:ok, message} ->
        conn
        |> put_status(:created)
        |> json(%{data: %{id: message.id, channel_id: message.channel_id}})

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Channel not found.")

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

      {:error, {:slowmode, seconds_left}} ->
        ErrorHelpers.render_slowmode(conn, seconds_left)

      {:error, reason} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_message",
          to_string(reason)
        )
    end
  end

  def create(conn, _params), do: ErrorHelpers.render_invalid_body(conn)
end
