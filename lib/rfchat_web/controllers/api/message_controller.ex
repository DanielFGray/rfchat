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

  def thread(conn, %{"message_id" => message_id}) do
    case Bots.get_thread_for_starter_message(conn.assigns.current_bot_scope, message_id) do
      {:ok, %{thread: thread}} ->
        json(conn, %{data: thread})

      {:error, :forbidden} ->
        ErrorHelpers.render_error(conn, :forbidden, "forbidden", "Bot cannot read that thread.")

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Thread not found.")

      {:error, _} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_params",
          "Invalid thread query."
        )
    end
  end

  def create_thread(conn, %{"message_id" => message_id} = params) do
    thread_params = Map.get(params, "thread", %{})

    case Bots.create_public_thread(conn.assigns.current_bot_scope, message_id, thread_params) do
      {:ok, %{thread: thread}} ->
        conn
        |> put_status(:created)
        |> json(%{data: thread})

      {:error, :forbidden} ->
        ErrorHelpers.render_error(
          conn,
          :forbidden,
          "forbidden",
          "Bot cannot create a thread from that message."
        )

      {:error, :not_found} ->
        ErrorHelpers.render_error(conn, :not_found, "not_found", "Starter message not found.")

      {:error, %Ecto.Changeset{} = changeset} ->
        ErrorHelpers.render_changeset_error(
          conn,
          :unprocessable_entity,
          "invalid_thread",
          changeset
        )

      {:error, _} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_thread",
          "Invalid thread request."
        )
    end
  end
end
