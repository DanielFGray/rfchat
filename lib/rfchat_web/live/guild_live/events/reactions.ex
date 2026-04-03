defmodule RfchatWeb.GuildLive.Events.Reactions do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, stream_insert: 3]

  alias Rfchat.Chat
  alias RfchatWeb.GuildLive.Events.Helpers
  alias RfchatWeb.GuildLive.State

  def handle_event("toggle_reaction", %{"id" => message_id, "emoji" => emoji_unicode}, socket) do
    message = Chat.get_message!(message_id)

    case Chat.toggle_reaction(message, socket.assigns.current_user, emoji_unicode) do
      {:ok, updated_message} ->
        {:noreply,
         socket
         |> assign(:reaction_picker_message_id, nil)
         |> State.rerender_messages([message.id])
         |> stream_insert(:messages, updated_message)}

      {:error, :invalid_emoji} ->
        {:noreply, put_flash(socket, :error, "Choose a valid reaction.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to add reactions here.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not toggle that reaction.")}
    end
  end

  def handle_event(
        "toggle_custom_reaction",
        %{"id" => message_id, "emoji_id" => emoji_id},
        socket
      ) do
    message = Chat.get_message!(message_id)

    case Chat.toggle_reaction(message, socket.assigns.current_user, %{"emoji_id" => emoji_id}) do
      {:ok, updated_message} ->
        {:noreply,
         socket
         |> assign(:reaction_picker_message_id, nil)
         |> State.rerender_messages([message.id])
         |> stream_insert(:messages, updated_message)}

      {:error, :invalid_emoji} ->
        {:noreply, put_flash(socket, :error, "Choose a valid custom emoji.")}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to use that emoji here.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not toggle that reaction.")}
    end
  end

  def handle_event("toggle_reaction_picker", %{"id" => message_id}, socket) do
    message_id = Helpers.normalize_message_id(message_id)
    previous_message_id = socket.assigns.reaction_picker_message_id
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    next_message_id = if previous_message_id == message_id, do: nil, else: message_id

    {:noreply,
     socket
     |> assign(:mobile_sidebar_open?, false)
     |> assign(:mobile_members_open?, false)
     |> assign(:reaction_picker_message_id, next_message_id)
     |> assign(:active_message_controls_id, nil)
     |> assign(:message_action_menu_id, nil)
     |> assign(:delete_confirmation_message_id, nil)
     |> State.rerender_messages([
       previous_message_id,
       next_message_id,
       previous_controls_id,
       previous_menu_id,
       previous_delete_id
     ])}
  end

  def handle_event("close_reaction_picker", _params, socket) do
    previous_message_id = socket.assigns.reaction_picker_message_id

    {:noreply,
     socket
     |> assign(:reaction_picker_message_id, nil)
     |> State.rerender_messages([previous_message_id])}
  end
end
