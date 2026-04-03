defmodule RfchatWeb.GuildLive.Events.Threads do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3]

  alias Rfchat.Chat
  alias RfchatWeb.GuildLive.Events.Helpers
  alias RfchatWeb.GuildLive.State

  def handle_event("create_thread", %{"id" => message_id}, socket) do
    message = Chat.get_message!(Helpers.normalize_message_id(message_id))

    case Chat.create_public_thread(
           socket.assigns.active_channel,
           message,
           socket.assigns.current_user
         ) do
      {:ok, thread} ->
        {:noreply,
         socket
         |> State.close_message_ui()
         |> State.refresh_thread_summaries_for_active_channel()
         |> State.open_thread(thread)}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to create threads here.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create that thread.")}
    end
  end

  def handle_event("open_thread", %{"id" => thread_id}, socket) do
    open_thread(thread_id, socket, focus?: false)
  end

  def handle_event("open_thread_focus", %{"id" => thread_id}, socket) do
    open_thread(thread_id, socket, focus?: true)
  end

  def handle_event("close_thread", _params, socket) do
    {:noreply, State.close_thread(socket)}
  end

  def handle_event("reply_in_thread", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)

    {:noreply,
     socket
     |> assign(:thread_reply_to_message, Chat.get_message!(message_id))
     |> State.rerender_active_thread_panel()}
  end

  def handle_event("cancel_thread_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:thread_reply_to_message, nil)
     |> State.rerender_active_thread_panel()}
  end

  def handle_event("send_thread_message", %{"message" => message_params}, socket) do
    cond do
      is_nil(socket.assigns.active_thread) ->
        {:noreply, put_flash(socket, :error, "Open a thread before replying.")}

      not socket.assigns.can_send_thread_messages? ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to send messages in this thread.")}

      true ->
        case Chat.create_message(
               socket.assigns.active_thread,
               socket.assigns.current_user,
               State.maybe_put_thread_reply(socket, message_params)
             ) do
          {:ok, message} ->
            Chat.mark_channel_read(
              socket.assigns.current_user,
              socket.assigns.active_thread,
              message
            )

            socket = push_event(socket, "composer:clear", %{target: "thread"})

            {:noreply,
             socket
             |> State.assign_thread_message_form()
             |> assign(:thread_reply_to_message, nil)
             |> State.maybe_insert_thread_message(message)
             |> State.refresh_thread_summaries_for_active_channel()}

          {:error, :forbidden} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "You do not have permission to send messages in this thread."
             )}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:thread_message_form, to_form(changeset, as: :message))
             |> State.rerender_active_thread_panel()}
        end
    end
  end

  defp open_thread(thread_id, socket, opts) do
    case Chat.get_thread_for_user(thread_id, socket.assigns.current_user) do
      {:ok, thread} ->
        {:noreply, State.open_thread(socket, thread, opts)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That thread no longer exists.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have access to that thread.")}
    end
  end
end
