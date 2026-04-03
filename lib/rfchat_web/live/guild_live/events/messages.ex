defmodule RfchatWeb.GuildLive.Events.Messages do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 1, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, stream_insert: 3]

  alias Rfchat.Chat
  alias RfchatWeb.GuildLive.Events.Helpers
  alias RfchatWeb.GuildLive.State

  def handle_info({:message_created, message}, socket) do
    socket =
      socket
      |> State.maybe_insert_message(message)
      |> State.maybe_insert_thread_message(message)
      |> State.maybe_push_mention_notification(message)

    {:noreply,
     socket
     |> State.refresh_unread_counts()
     |> State.refresh_unread_mentions()
     |> State.refresh_member_presence()}
  end

  def handle_info({:message_updated, message}, socket) do
    {:noreply,
     socket
     |> State.maybe_stream_update_message(message)
     |> State.maybe_stream_update_thread_message(message)}
  end

  def handle_info({:message_deleted, message}, socket) do
    {:noreply,
     socket
     |> State.maybe_stream_update_message(message)
     |> State.maybe_stream_update_thread_message(message)}
  end

  def handle_event("toggle_message_controls", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)
    message = Chat.get_message!(message_id)

    if Helpers.can_open_message_controls?(
         message,
         socket.assigns.current_user,
         socket.assigns.can_send_messages?,
         socket.assigns.can_manage_messages?
       ) do
      previous_controls_id = socket.assigns.active_message_controls_id
      previous_menu_id = socket.assigns.message_action_menu_id
      previous_delete_id = socket.assigns.delete_confirmation_message_id
      previous_picker_id = socket.assigns.reaction_picker_message_id

      next_message_id =
        if previous_controls_id == message_id and is_nil(previous_menu_id) and
             is_nil(previous_delete_id),
           do: nil,
           else: message_id

      {:noreply,
       socket
       |> assign(:mobile_sidebar_open?, false)
       |> assign(:mobile_members_open?, false)
       |> assign(:reaction_picker_message_id, nil)
       |> assign(:message_action_menu_id, nil)
       |> assign(:delete_confirmation_message_id, nil)
       |> assign(:active_message_controls_id, next_message_id)
       |> State.rerender_messages([
         previous_controls_id,
         previous_menu_id,
         previous_delete_id,
         previous_picker_id,
         next_message_id
       ])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_message_action_menu", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id
    previous_picker_id = socket.assigns.reaction_picker_message_id
    next_menu_id = if previous_menu_id == message_id, do: nil, else: message_id

    {:noreply,
     socket
     |> assign(:reaction_picker_message_id, nil)
     |> assign(
       :active_message_controls_id,
       if(next_menu_id, do: message_id, else: previous_controls_id)
     )
     |> assign(:message_action_menu_id, next_menu_id)
     |> assign(:delete_confirmation_message_id, nil)
     |> State.rerender_messages([
       previous_controls_id,
       previous_menu_id,
       previous_delete_id,
       previous_picker_id,
       message_id,
       next_menu_id
     ])}
  end

  def handle_event("close_message_action_menu", _params, socket) do
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    {:noreply,
     socket
     |> assign(:message_action_menu_id, nil)
     |> assign(:delete_confirmation_message_id, nil)
     |> State.rerender_messages([previous_controls_id, previous_menu_id, previous_delete_id])}
  end

  def handle_event("confirm_delete_message", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    {:noreply,
     socket
     |> assign(:active_message_controls_id, message_id)
     |> assign(:message_action_menu_id, message_id)
     |> assign(:delete_confirmation_message_id, message_id)
     |> State.rerender_messages([
       previous_controls_id,
       previous_menu_id,
       previous_delete_id,
       message_id
     ])}
  end

  def handle_event("cancel_delete_message", _params, socket) do
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    {:noreply,
     socket
     |> assign(:delete_confirmation_message_id, nil)
     |> State.rerender_messages([previous_delete_id, socket.assigns.message_action_menu_id])}
  end

  def handle_event("send_message", %{"message" => message_params}, socket) do
    cond do
      is_nil(socket.assigns.active_channel) ->
        {:noreply,
         socket
         |> put_flash(:error, "Choose a channel before sending a message.")
         |> State.assign_message_form()}

      not Chat.can_send_messages?(socket.assigns.active_channel, socket.assigns.current_user) ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have permission to send messages in that channel.")
         |> State.assign_message_form()}

      true ->
        case Chat.create_message(
               socket.assigns.active_channel,
               socket.assigns.current_user,
               State.maybe_put_reply(socket, message_params)
             ) do
          {:ok, message} ->
            Chat.mark_channel_read(
              socket.assigns.current_user,
              socket.assigns.active_channel,
              message
            )

            socket = push_event(socket, "composer:clear", %{target: "channel"})

            {:noreply,
             socket
             |> State.assign_message_form()
             |> State.clear_reply_to_message()
             |> State.maybe_insert_message(message)
             |> State.refresh_unread_counts()
             |> State.refresh_unread_mentions()
             |> State.refresh_member_presence()}

          {:error, :forbidden} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               "You do not have permission to send that message in this channel."
             )
             |> State.assign_message_form()}

          {:error, changeset} ->
            {:noreply, assign(socket, :message_form, to_form(changeset))}
        end
    end
  end

  def handle_event("reply_message", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    {:noreply,
     socket
     |> assign(:reply_to_message, Chat.get_message!(message_id))
     |> State.close_message_ui()
     |> State.rerender_messages([
       message_id,
       previous_controls_id,
       previous_menu_id,
       previous_delete_id
     ])}
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, State.clear_reply_to_message(socket)}
  end

  def handle_event("edit_message", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)
    message = Chat.get_message!(message_id)

    if message.author_id == socket.assigns.current_user.id do
      form = message |> Chat.change_message(%{body: message.body}) |> to_form(as: :message)
      previous_controls_id = socket.assigns.active_message_controls_id
      previous_menu_id = socket.assigns.message_action_menu_id
      previous_delete_id = socket.assigns.delete_confirmation_message_id

      {:noreply,
       socket
       |> State.close_message_ui()
       |> assign(:editing_message_id, message.id)
       |> assign(:editing_form, form)
       |> State.rerender_messages([
         message.id,
         previous_controls_id,
         previous_menu_id,
         previous_delete_id
       ])
       |> stream_insert(:messages, message)}
    else
      {:noreply, put_flash(socket, :error, "You can only edit your own messages.")}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_message_id, nil)
     |> assign(:editing_form, nil)}
  end

  def handle_event("save_edit", %{"message" => %{"id" => message_id, "body" => body}}, socket) do
    message = Chat.get_message!(message_id)

    case Chat.update_message(message, socket.assigns.current_user, %{body: body}) do
      {:ok, updated_message} ->
        {:noreply,
         socket
         |> assign(:editing_message_id, nil)
         |> assign(:editing_form, nil)
         |> stream_insert(:messages, updated_message)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to edit that message.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :editing_form, to_form(changeset, as: :message))}
    end
  end

  def handle_event("delete_message", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)
    message = Chat.get_message!(message_id)
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    case Chat.delete_message(message, socket.assigns.current_user) do
      {:ok, deleted_message} ->
        {:noreply,
         socket
         |> State.close_message_ui()
         |> assign(:editing_message_id, nil)
         |> assign(:editing_form, nil)
         |> State.rerender_messages([
           message_id,
           previous_controls_id,
           previous_menu_id,
           previous_delete_id
         ])
         |> stream_insert(:messages, deleted_message)}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to delete that message.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete that message.")}
    end
  end
end
