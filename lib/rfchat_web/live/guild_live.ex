defmodule RfchatWeb.GuildLive do
  use RfchatWeb, :live_view

  alias Rfchat.Accounts
  alias Rfchat.Chat
  alias RfchatWeb.GuildLive.State
  alias RfchatWeb.Live.SharedHelpers

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels_for_user(current_user)
    :ok = Chat.ensure_channel_memberships_for_user(current_user, channels)

    if connected?(socket) do
      Chat.subscribe_to_channel_events()
    end

    server_settings = Chat.get_server_settings()

    socket =
      socket
      |> assign(:server_settings, server_settings)
      |> assign(:guild_name, server_settings.name)
      |> assign(:current_server, server_settings)
      |> assign(:page_title, server_settings.name)
      |> assign(:current_user, current_user)
      |> assign(:channels, channels)
      |> assign(:channel_sections, Chat.list_channel_tree_for_user(current_user))
      |> assign(:custom_emojis, SharedHelpers.emoji_entries_for_picker(current_user))
      |> assign(:custom_emojis_json, emoji_entries_json_for_picker(current_user))
      |> assign(:member_presence, Accounts.list_members_with_presence())
      |> assign(:notification_setting, Chat.get_user_notification_setting(current_user))
      |> assign(:composer_mentions_json, Jason.encode!(Chat.composer_mentions()))
      |> assign(:composer_commands_json, Jason.encode!(Chat.composer_slash_commands()))
      |> assign(:unread_counts, Chat.unread_counts_for_user(current_user, channels))
      |> assign(:unread_mentions, Chat.unread_mentions_for_user(current_user, channels))
      |> assign(:mobile_sidebar_open?, false)
      |> assign(:mobile_members_open?, false)
      |> assign(:reaction_picker_message_id, nil)
      |> assign(:active_message_controls_id, nil)
      |> assign(:message_action_menu_id, nil)
      |> assign(:delete_confirmation_message_id, nil)
      |> assign(:active_channel, nil)
      |> assign(:can_send_messages?, false)
      |> assign(:can_add_reactions?, false)
      |> assign(:can_manage_messages?, false)
      |> assign(:can_mention_everyone?, false)
      |> assign(:can_create_public_threads?, false)
      |> assign(:can_send_thread_messages?, false)
      |> assign(:reply_to_message, nil)
      |> assign(:thread_reply_to_message, nil)
      |> assign(:editing_message_id, nil)
      |> assign(:editing_form, nil)
      |> assign(:message_count, 0)
      |> assign(:messages_empty?, true)
      |> assign(:thread_summaries, %{})
      |> assign(:active_thread, nil)
      |> assign(:thread_focus?, false)
      |> assign(:thread_message_count, 0)
      |> assign(:thread_messages_empty?, true)
      |> State.assign_message_form()
      |> State.assign_thread_message_form()
      |> stream(:messages, [], reset: true)
      |> stream(:thread_messages, [], reset: true)

    case {Chat.list_channels(), List.first(channels)} do
      {[], _none_visible} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "This guild has not been bootstrapped yet. Run `mix run priv/repo/seeds.exs`."
         )}

      {_all_channels, nil} ->
        {:ok,
         socket
         |> put_flash(:error, "You do not currently have access to any channels in this server.")}

      {_all_channels, active_channel} ->
        {:ok, State.load_channel(socket, active_channel)}
    end
  end

  @impl true
  def handle_params(%{"thread" => thread_id} = params, _uri, socket) do
    socket =
      case params do
        %{"channel" => slug} ->
          case Chat.get_channel_by_slug_for_user(slug, socket.assigns.current_user) do
            {:ok, channel} ->
              socket
              |> assign(:active_thread, nil)
              |> assign(:thread_focus?, false)
              |> State.load_channel(channel)

            _ ->
              socket
          end

        _ ->
          socket
      end

    case Chat.get_thread_for_user(thread_id, socket.assigns.current_user) do
      {:ok, thread} ->
        {:noreply, State.open_thread(socket, thread, focus?: true)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That thread does not exist.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have access to that thread.")}
    end
  end

  def handle_params(%{"channel" => slug}, _uri, socket) do
    case Chat.get_channel_by_slug_for_user(slug, socket.assigns.current_user) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:active_thread, nil)
         |> assign(:thread_focus?, false)
         |> State.load_channel(channel)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "That channel does not exist.")
         |> State.redirect_to_default_channel()}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have access to that channel.")
         |> State.redirect_to_default_channel()}
    end
  end

  def handle_params(_params, _uri, socket) do
    case {socket.assigns.active_channel, List.first(socket.assigns.channels)} do
      {nil, %{} = channel} -> {:noreply, State.load_channel(socket, channel)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
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

  @impl true
  def handle_info({:message_updated, message}, socket) do
    {:noreply,
     socket
     |> State.maybe_stream_update_message(message)
     |> State.maybe_stream_update_thread_message(message)}
  end

  @impl true
  def handle_info({:message_deleted, message}, socket) do
    {:noreply,
     socket
     |> State.maybe_stream_update_message(message)
     |> State.maybe_stream_update_thread_message(message)}
  end

  @impl true
  def handle_info({:channel_created, channel}, socket) do
    {:noreply, State.maybe_refresh_thread_summaries(socket, channel)}
  end

  @impl true
  def handle_info({:channel_updated, _channel}, socket) do
    {:noreply, State.refresh_channels(socket)}
  end

  @impl true
  def handle_info({:channel_deleted, channel}, socket) do
    socket = State.refresh_channels(socket)

    cond do
      socket.assigns.active_channel && socket.assigns.active_channel.id == channel.id ->
        {:noreply,
         socket
         |> put_flash(:info, "Channel deleted.")
         |> State.redirect_to_default_channel()}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:channels_reordered, socket) do
    {:noreply, State.refresh_channels(socket)}
  end

  @impl true
  def handle_event("toggle_mobile_sidebar", _params, socket) do
    next_open? = !socket.assigns.mobile_sidebar_open?

    {:noreply,
     socket
     |> State.close_message_ui()
     |> assign(:mobile_members_open?, false)
     |> assign(:mobile_sidebar_open?, next_open?)}
  end

  @impl true
  def handle_event("close_mobile_sidebar", _params, socket) do
    {:noreply, assign(socket, :mobile_sidebar_open?, false)}
  end

  @impl true
  def handle_event("toggle_mobile_members", _params, socket) do
    next_open? = !socket.assigns.mobile_members_open?

    {:noreply,
     socket
     |> State.close_message_ui()
     |> assign(:mobile_sidebar_open?, false)
     |> assign(:mobile_members_open?, next_open?)}
  end

  @impl true
  def handle_event("close_mobile_members", _params, socket) do
    {:noreply, assign(socket, :mobile_members_open?, false)}
  end

  @impl true
  def handle_event("toggle_message_controls", %{"id" => message_id}, socket) do
    message_id = normalize_message_id(message_id)
    message = Chat.get_message!(message_id)

    if can_open_message_controls?(
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

  @impl true
  def handle_event("toggle_message_action_menu", %{"id" => message_id}, socket) do
    message_id = normalize_message_id(message_id)
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

  @impl true
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

  @impl true
  def handle_event("confirm_delete_message", %{"id" => message_id}, socket) do
    message_id = normalize_message_id(message_id)
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

  @impl true
  def handle_event("cancel_delete_message", _params, socket) do
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    {:noreply,
     socket
     |> assign(:delete_confirmation_message_id, nil)
     |> State.rerender_messages([previous_delete_id, socket.assigns.message_action_menu_id])}
  end

  @impl true
  def handle_event("enable_desktop_mentions", _params, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_user, %{
           desktop_enabled: true,
           notify_on_mentions: true
         }) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:notification_setting, setting)
         |> push_event("notifications:request-permission", %{})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not enable mention alerts.")}
    end
  end

  @impl true
  def handle_event("disable_desktop_mentions", _params, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_user, %{
           desktop_enabled: false
         }) do
      {:ok, setting} ->
        {:noreply, assign(socket, :notification_setting, setting)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not disable mention alerts.")}
    end
  end

  @impl true
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

  @impl true
  def handle_event("create_thread", %{"id" => message_id}, socket) do
    message = Chat.get_message!(normalize_message_id(message_id))

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

  @impl true
  def handle_event("open_thread", %{"id" => thread_id}, socket) do
    case Chat.get_thread_for_user(thread_id, socket.assigns.current_user) do
      {:ok, thread} ->
        {:noreply, State.open_thread(socket, thread)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That thread no longer exists.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have access to that thread.")}
    end
  end

  @impl true
  def handle_event("open_thread_focus", %{"id" => thread_id}, socket) do
    case Chat.get_thread_for_user(thread_id, socket.assigns.current_user) do
      {:ok, thread} ->
        {:noreply, State.open_thread(socket, thread, focus?: true)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That thread no longer exists.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have access to that thread.")}
    end
  end

  @impl true
  def handle_event("close_thread", _params, socket) do
    {:noreply, State.close_thread(socket)}
  end

  @impl true
  def handle_event("reply_in_thread", %{"id" => message_id}, socket) do
    message_id = normalize_message_id(message_id)

    {:noreply,
     socket
     |> assign(:thread_reply_to_message, Chat.get_message!(message_id))
     |> State.rerender_active_thread_panel()}
  end

  @impl true
  def handle_event("cancel_thread_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:thread_reply_to_message, nil)
     |> State.rerender_active_thread_panel()}
  end

  @impl true
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

  @impl true
  def handle_event("reply_message", %{"id" => message_id}, socket) do
    message_id = normalize_message_id(message_id)
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

  @impl true
  def handle_event("cancel_reply", _params, socket) do
    {:noreply, State.clear_reply_to_message(socket)}
  end

  @impl true
  def handle_event("edit_message", %{"id" => message_id}, socket) do
    message_id = normalize_message_id(message_id)
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

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_message_id, nil)
     |> assign(:editing_form, nil)}
  end

  @impl true
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

  @impl true
  def handle_event("delete_message", %{"id" => message_id}, socket) do
    message_id = normalize_message_id(message_id)
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

  @impl true
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

  @impl true
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

  @impl true
  def handle_event("toggle_reaction_picker", %{"id" => message_id}, socket) do
    message_id = normalize_message_id(message_id)
    previous_message_id = socket.assigns.reaction_picker_message_id
    previous_controls_id = socket.assigns.active_message_controls_id
    previous_menu_id = socket.assigns.message_action_menu_id
    previous_delete_id = socket.assigns.delete_confirmation_message_id

    next_message_id =
      if previous_message_id == message_id, do: nil, else: message_id

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

  @impl true
  def handle_event("close_reaction_picker", _params, socket) do
    previous_message_id = socket.assigns.reaction_picker_message_id

    {:noreply,
     socket
     |> assign(:reaction_picker_message_id, nil)
     |> State.rerender_messages([previous_message_id])}
  end

  defp emoji_entries_json_for_picker(current_user) do
    Jason.encode!(%{
      custom: SharedHelpers.emoji_entries_for_picker(current_user),
      branding: SharedHelpers.server_branding()
    })
  end

  defp own_message?(message, current_user), do: message.author_id == current_user.id

  defp normalize_message_id(message_id), do: message_id

  defp can_open_message_controls?(message, current_user, can_send_messages?, can_manage_messages?) do
    not deleted_message?(message) and
      (can_send_messages? or own_message?(message, current_user) or can_manage_messages?)
  end

  defp deleted_message?(message) do
    not is_nil(message.deleted_at) or Map.get(message.metadata || %{}, "deleted", false)
  end
end
