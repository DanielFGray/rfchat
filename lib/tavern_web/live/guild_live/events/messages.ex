defmodule TavernWeb.GuildLive.Events.Messages do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 1, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, stream_insert: 3]

  alias Tavern.Accounts
  alias Tavern.Chat
  alias TavernWeb.GuildLive.Events.Helpers
  alias TavernWeb.GuildLive.State

  def handle_info({:message_created, message}, socket) do
    socket =
      socket
      |> State.maybe_insert_message(message)
      |> State.maybe_insert_thread_message(message)
      |> State.maybe_push_mention_notification(message)
      |> update_unread_state(message)

    {:noreply, socket}
  end

  def handle_info({type, channel_id, user_id}, socket)
      when type in [:typing_started, :typing_stopped] do
    socket =
      socket
      |> maybe_refresh_typing_users(channel_id, type, user_id)
      |> maybe_refresh_thread_typing_users(channel_id, type, user_id)

    {:noreply, socket}
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

    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         true <-
           Helpers.can_open_message_controls?(
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
      _closed -> {:noreply, socket}
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

      not socket.assigns.can_send_messages? ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have permission to send messages in that channel.")
         |> State.assign_message_form()}

      true ->
        case Chat.create_message(
               socket.assigns.current_scope,
               socket.assigns.active_channel.id,
               State.maybe_put_reply(socket, message_params)
             ) do
          {:ok, message} ->
            Chat.clear_typing(socket.assigns.current_scope, socket.assigns.active_channel.id)
            socket = push_event(socket, "composer:clear", %{target: "channel"})

            {:noreply,
             socket
             |> State.assign_message_form()
             |> State.clear_reply_to_message()
             |> State.refresh_typing_users()
             |> State.maybe_insert_message(message)}

          {:error, {:slowmode, seconds_left}} ->
            {:noreply, put_flash(socket, :error, Helpers.slowmode_message(seconds_left))}

          {:error, reason} when reason in [:forbidden, :not_found] ->
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

  def handle_event("typing_ping", _params, socket) do
    case socket.assigns.active_channel do
      %{} = channel ->
        _ = Chat.announce_typing(socket.assigns.current_scope, channel.id)
        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("typing_stop", _params, socket) do
    case socket.assigns.active_channel do
      %{} = channel ->
        _ = Chat.clear_typing(socket.assigns.current_scope, channel.id)
        {:noreply, State.refresh_typing_users(socket)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("typing_ping_thread", _params, socket) do
    case socket.assigns.active_thread do
      %{} = thread ->
        _ = Chat.announce_typing(socket.assigns.current_scope, thread.id)
        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("typing_stop_thread", _params, socket) do
    case socket.assigns.active_thread do
      %{} = thread ->
        _ = Chat.clear_typing(socket.assigns.current_scope, thread.id)
        {:noreply, State.refresh_thread_typing_users(socket)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("reply_message", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    case State.fetch_open_message(socket, message_id) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:reply_to_message, message)
         |> State.close_message_ui()
         |> State.rerender_messages([
           message_id,
           previous_controls_id,
           previous_menu_id,
           previous_delete_id
         ])}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, State.clear_reply_to_message(socket)}
  end

  def handle_event("edit_message", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)

    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         true <- message.author_id == socket.assigns.current_user.id do
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
      :error -> {:noreply, socket}
      false -> {:noreply, put_flash(socket, :error, "You can only edit your own messages.")}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_message_id, nil)
     |> assign(:editing_form, nil)}
  end

  def handle_event("save_edit", %{"message" => %{"id" => message_id, "body" => body}}, socket) do
    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         {:ok, updated_message} <-
           Chat.update_message(socket.assigns.current_scope, message.id, %{body: body}) do
      {:noreply,
       socket
       |> assign(:editing_message_id, nil)
       |> assign(:editing_form, nil)
       |> stream_insert(:messages, updated_message)}
    else
      :error ->
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, socket}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to edit that message.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :editing_form, to_form(changeset, as: :message))}
    end
  end

  def handle_event("delete_message", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    with {:ok, message} <- State.fetch_open_message(socket, message_id),
         {:ok, deleted_message} <- Chat.delete_message(socket.assigns.current_scope, message.id) do
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
    else
      :error ->
        {:noreply, socket}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to delete that message.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete that message.")}
    end
  end

  defp update_unread_state(socket, message) do
    socket
    |> maybe_increment_unread_count(message)
    |> maybe_increment_unread_mentions(message)
  end

  defp maybe_increment_unread_count(socket, message) do
    if increment_unread_count?(socket, message) do
      assign(
        socket,
        :unread_counts,
        Map.update(socket.assigns.unread_counts || %{}, message.channel_id, 1, &(&1 + 1))
      )
    else
      socket
    end
  end

  defp maybe_increment_unread_mentions(socket, message) do
    if increment_unread_mentions?(socket, message) do
      assign(
        socket,
        :unread_mentions,
        Map.update(socket.assigns.unread_mentions || %{}, message.channel_id, 1, &(&1 + 1))
      )
    else
      socket
    end
  end

  defp increment_unread_count?(socket, message) do
    current_user = socket.assigns.current_user
    active_channel = socket.assigns.active_channel

    message.author_id != current_user.id and
      (is_nil(active_channel) or active_channel.id != message.channel_id)
  end

  defp increment_unread_mentions?(socket, message) do
    current_user = socket.assigns.current_user
    active_channel = socket.assigns.active_channel

    message.author_id != current_user.id and
      (is_nil(active_channel) or active_channel.id != message.channel_id) and
      Chat.message_mentions_user?(message, current_user)
  end

  defp maybe_refresh_typing_users(socket, channel_id, type, user_id) do
    if socket.assigns.active_channel && socket.assigns.active_channel.id == channel_id do
      update_typing_assign(socket, :typing_users, type, user_id)
    else
      socket
    end
  end

  defp maybe_refresh_thread_typing_users(socket, channel_id, type, user_id) do
    if socket.assigns.active_thread && socket.assigns.active_thread.id == channel_id do
      update_typing_assign(socket, :thread_typing_users, type, user_id)
    else
      socket
    end
  end

  defp update_typing_assign(socket, assign_key, :typing_started, user_id) do
    # The typer is decided by `Chat.start_typing`, and this socket subscribes only to channels it
    # may view. A typer who is not an active member has no member row to show.
    if user_id == socket.assigns.current_user.id do
      socket
    else
      case Accounts.get_member(socket.assigns.current_scope, user_id) do
        nil ->
          socket

        user ->
          assign(socket, assign_key, merge_typing_user(socket.assigns[assign_key] || [], user))
      end
    end
  end

  defp update_typing_assign(socket, assign_key, :typing_stopped, user_id) do
    assign(socket, assign_key, Enum.reject(socket.assigns[assign_key] || [], &(&1.id == user_id)))
  end

  defp merge_typing_user(users, user) do
    users
    |> Enum.reject(&(&1.id == user.id))
    |> Kernel.++([user])
    |> Enum.sort_by(&{&1.display_name, &1.username})
  end
end
