defmodule RfchatWeb.GuildLive do
  use RfchatWeb, :live_view

  alias Rfchat.Accounts
  alias Rfchat.Chat
  alias Rfchat.Chat.Message
  alias RfchatWeb.Live.SharedHelpers

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels_for_user(current_user)
    :ok = Chat.ensure_channel_memberships_for_user(current_user, channels)
    can_manage_channels? = SharedHelpers.can_manage_channels?(socket.assigns.current_scope)
    can_manage_emojis? = SharedHelpers.can_manage_emojis?(socket.assigns.current_scope)
    can_moderate_members? = SharedHelpers.can_moderate_members?(socket.assigns.current_scope)

    if connected?(socket) do
      Chat.subscribe_to_channel_events()
    end

    server_settings = Chat.get_server_settings()

    socket =
      socket
      |> allow_upload(:emoji_image,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 512_000
      )
      |> assign(:server_settings, server_settings)
      |> assign(:guild_name, server_settings.name)
      |> assign(:current_server, server_settings)
      |> assign(:page_title, server_settings.name)
      |> assign(:current_user, current_user)
      |> assign(:can_manage_channels?, can_manage_channels?)
      |> assign(:can_manage_emojis?, can_manage_emojis?)
      |> assign(:can_moderate_members?, can_moderate_members?)
      |> assign(:channels, channels)
      |> assign(:channel_sections, Chat.list_channel_tree_for_user(current_user))
      |> assign(
        :all_channel_sections,
        SharedHelpers.channel_sections_for_manager(can_manage_channels?)
      )
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
      |> assign(:manage_channels_open?, false)
      |> assign(:manage_emojis_open?, false)
      |> assign(:reaction_picker_message_id, nil)
      |> assign(:active_message_controls_id, nil)
      |> assign(:message_action_menu_id, nil)
      |> assign(:delete_confirmation_message_id, nil)
      |> assign(:member_action_user_id, nil)
      |> assign(:moderation_cases, [])
      |> assign(:member_action_form, to_form(Chat.change_moderation_action(%{}), as: :moderation))
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
      |> assign(:channel_form_mode, :create_text)
      |> assign(:channel_form_title, "Create text channel")
      |> assign(:editing_channel_id, nil)
      |> assign(:emoji_form, to_form(Chat.change_emoji(%Chat.Emoji{}, %{}), as: :emoji))
      |> assign(:message_count, 0)
      |> assign(:messages_empty?, true)
      |> assign(:thread_summaries, %{})
      |> assign(:active_thread, nil)
      |> assign(:thread_focus?, false)
      |> assign(:thread_message_count, 0)
      |> assign(:thread_messages_empty?, true)
      |> assign_message_form()
      |> assign_thread_message_form()
      |> SharedHelpers.assign_channel_form()
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
        {:ok, load_channel(socket, active_channel)}
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
              |> load_channel(channel)

            _ ->
              socket
          end

        _ ->
          socket
      end

    case Chat.get_thread_for_user(thread_id, socket.assigns.current_user) do
      {:ok, thread} ->
        {:noreply, open_thread(socket, thread, focus?: true)}

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
         |> load_channel(channel)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "That channel does not exist.")
         |> redirect_to_default_channel()}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have access to that channel.")
         |> redirect_to_default_channel()}
    end
  end

  def handle_params(_params, _uri, socket) do
    case {socket.assigns.active_channel, List.first(socket.assigns.channels)} do
      {nil, %{} = channel} -> {:noreply, load_channel(socket, channel)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:message_created, message}, socket) do
    socket =
      socket
      |> maybe_insert_message(message)
      |> maybe_insert_thread_message(message)
      |> maybe_push_mention_notification(message)

    {:noreply,
     socket
     |> refresh_unread_counts()
     |> refresh_unread_mentions()
     |> refresh_member_presence()}
  end

  @impl true
  def handle_info({:message_updated, message}, socket) do
    {:noreply,
     socket
     |> maybe_stream_update_message(message)
     |> maybe_stream_update_thread_message(message)}
  end

  @impl true
  def handle_info({:message_deleted, message}, socket) do
    {:noreply,
     socket
     |> maybe_stream_update_message(message)
     |> maybe_stream_update_thread_message(message)}
  end

  @impl true
  def handle_info({:channel_created, channel}, socket) do
    {:noreply, maybe_refresh_thread_summaries(socket, channel)}
  end

  @impl true
  def handle_info({:channel_updated, _channel}, socket) do
    {:noreply, refresh_channels(socket)}
  end

  @impl true
  def handle_info({:channel_deleted, channel}, socket) do
    socket = refresh_channels(socket)

    cond do
      socket.assigns.active_channel && socket.assigns.active_channel.id == channel.id ->
        {:noreply,
         socket
         |> put_flash(:info, "Channel deleted.")
         |> redirect_to_default_channel()}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:channels_reordered, socket) do
    {:noreply, refresh_channels(socket)}
  end

  @impl true
  def handle_event("toggle_mobile_sidebar", _params, socket) do
    next_open? = !socket.assigns.mobile_sidebar_open?

    {:noreply,
     socket
     |> close_message_ui()
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
     |> close_message_ui()
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
       |> rerender_messages([
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
     |> rerender_messages([
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
     |> rerender_messages([previous_controls_id, previous_menu_id, previous_delete_id])}
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
     |> rerender_messages([
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
     |> rerender_messages([previous_delete_id, socket.assigns.message_action_menu_id])}
  end

  @impl true
  def handle_event("toggle_manage_channels", _params, socket) do
    if socket.assigns.can_manage_channels? do
      {:noreply, assign(socket, :manage_channels_open?, !socket.assigns.manage_channels_open?)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("close_manage_channels", _params, socket) do
    {:noreply, assign(socket, :manage_channels_open?, false)}
  end

  @impl true
  def handle_event("toggle_manage_emojis", _params, socket) do
    if socket.assigns.can_manage_emojis? do
      {:noreply, assign(socket, :manage_emojis_open?, !socket.assigns.manage_emojis_open?)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage emojis.")}
    end
  end

  @impl true
  def handle_event("close_manage_emojis", _params, socket) do
    {:noreply, assign(socket, :manage_emojis_open?, false)}
  end

  @impl true
  def handle_event("toggle_member_actions", %{"id" => user_id}, socket) do
    if socket.assigns.can_moderate_members? do
      next_user_id = if socket.assigns.member_action_user_id == user_id, do: nil, else: user_id

      moderation_cases =
        if next_user_id, do: Chat.list_moderation_cases_for_user(user_id), else: []

      {:noreply,
       socket
       |> assign(:member_action_user_id, next_user_id)
       |> assign(:moderation_cases, moderation_cases)
       |> assign(
         :member_action_form,
         to_form(Chat.change_moderation_action(%{}), as: :moderation)
       )}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to moderate members.")}
    end
  end

  @impl true
  def handle_event("close_member_actions", _params, socket) do
    {:noreply,
     socket
     |> assign(:member_action_user_id, nil)
     |> assign(:moderation_cases, [])
     |> assign(:member_action_form, to_form(Chat.change_moderation_action(%{}), as: :moderation))}
  end

  @impl true
  def handle_event("new_channel_form", %{"mode" => mode}, socket) do
    if socket.assigns.can_manage_channels? do
      {:noreply,
       socket
       |> SharedHelpers.assign_channel_form_mode(mode)
       |> SharedHelpers.assign_channel_form()}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("edit_channel", %{"id" => channel_id}, socket) do
    if socket.assigns.can_manage_channels? do
      channel = Chat.get_channel!(channel_id)

      {:noreply,
       socket
       |> assign(:manage_channels_open?, true)
       |> assign(:editing_channel_id, channel.id)
       |> SharedHelpers.assign_channel_form_mode(SharedHelpers.edit_mode_for(channel))
       |> SharedHelpers.assign_channel_form(channel)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("cancel_channel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_channel_id, nil)
     |> SharedHelpers.assign_channel_form_mode(:create_text)
     |> SharedHelpers.assign_channel_form()}
  end

  @impl true
  def handle_event("save_channel", %{"channel" => channel_params}, socket) do
    if socket.assigns.can_manage_channels? do
      save_channel(socket, channel_params)
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("delete_channel", %{"id" => channel_id}, socket) do
    if socket.assigns.can_manage_channels? do
      channel = Chat.get_channel!(channel_id)

      case Chat.delete_channel(channel) do
        {:ok, _channel} ->
          socket =
            socket
            |> refresh_channels()
            |> assign(:editing_channel_id, nil)
            |> SharedHelpers.assign_channel_form_mode(:create_text)
            |> SharedHelpers.assign_channel_form()
            |> put_flash(:info, "Channel deleted.")

          if socket.assigns.active_channel && socket.assigns.active_channel.id == channel_id do
            {:noreply, redirect_to_default_channel(socket)}
          else
            {:noreply, socket}
          end

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not delete that channel.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("move_channel", %{"id" => channel_id, "direction" => direction}, socket) do
    if socket.assigns.can_manage_channels? do
      case move_channel(channel_id, direction) do
        :ok -> {:noreply, refresh_channels(socket)}
        :error -> {:noreply, put_flash(socket, :error, "Could not reorder that channel.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
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
         |> assign_message_form()}

      not Chat.can_send_messages?(socket.assigns.active_channel, socket.assigns.current_user) ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have permission to send messages in that channel.")
         |> assign_message_form()}

      true ->
        case Chat.create_message(
               socket.assigns.active_channel,
               socket.assigns.current_user,
               maybe_put_reply(socket, message_params)
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
             |> assign_message_form()
             |> clear_reply_to_message()
             |> maybe_insert_message(message)
             |> refresh_unread_counts()
             |> refresh_unread_mentions()
             |> refresh_member_presence()}

          {:error, :forbidden} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               "You do not have permission to send that message in this channel."
             )
             |> assign_message_form()}

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
         |> close_message_ui()
         |> refresh_thread_summaries_for_active_channel()
         |> open_thread(thread)}

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
        {:noreply, open_thread(socket, thread)}

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
        {:noreply, open_thread(socket, thread, focus?: true)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That thread no longer exists.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have access to that thread.")}
    end
  end

  @impl true
  def handle_event("close_thread", _params, socket) do
    {:noreply, close_thread(socket)}
  end

  @impl true
  def handle_event("reply_in_thread", %{"id" => message_id}, socket) do
    message_id = normalize_message_id(message_id)

    {:noreply,
     socket
     |> assign(:thread_reply_to_message, Chat.get_message!(message_id))
     |> rerender_active_thread_panel()}
  end

  @impl true
  def handle_event("cancel_thread_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:thread_reply_to_message, nil)
     |> rerender_active_thread_panel()}
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
               maybe_put_thread_reply(socket, message_params)
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
             |> assign_thread_message_form()
             |> assign(:thread_reply_to_message, nil)
             |> maybe_insert_thread_message(message)
             |> refresh_thread_summaries_for_active_channel()}

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
             |> rerender_active_thread_panel()}
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
     |> close_message_ui()
     |> rerender_messages([
       message_id,
       previous_controls_id,
       previous_menu_id,
       previous_delete_id
     ])}
  end

  @impl true
  def handle_event("cancel_reply", _params, socket) do
    {:noreply, clear_reply_to_message(socket)}
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
       |> close_message_ui()
       |> assign(:editing_message_id, message.id)
       |> assign(:editing_form, form)
       |> rerender_messages([
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
         |> close_message_ui()
         |> assign(:editing_message_id, nil)
         |> assign(:editing_form, nil)
         |> rerender_messages([
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
         |> rerender_messages([message.id])
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
         |> rerender_messages([message.id])
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
     |> rerender_messages([
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
     |> rerender_messages([previous_message_id])}
  end

  @impl true
  def handle_event("save_emoji", %{"emoji" => emoji_params}, socket) do
    if socket.assigns.can_manage_emojis? do
      save_emoji(socket, emoji_params)
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage emojis.")}
    end
  end

  @impl true
  def handle_event("delete_emoji", %{"id" => emoji_id}, socket) do
    if socket.assigns.can_manage_emojis? do
      emoji = Chat.get_emoji!(emoji_id)

      case Chat.delete_custom_emoji(emoji) do
        {:ok, _emoji} ->
          {:noreply,
           socket
           |> refresh_custom_emojis()
           |> put_flash(:info, "Emoji deleted.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not delete that emoji.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage emojis.")}
    end
  end

  @impl true
  def handle_event("moderate_member", %{"user_id" => user_id, "moderation" => params}, socket) do
    if socket.assigns.can_moderate_members? do
      actor = socket.assigns.current_user
      subject = Accounts.get_user_with_membership!(user_id)

      case run_member_moderation(actor, subject, params) do
        {:ok, _subject, _case, message} ->
          {:noreply,
           socket
           |> refresh_member_presence()
           |> assign(:moderation_cases, Chat.list_moderation_cases_for_user(user_id))
           |> assign(
             :member_action_form,
             to_form(Chat.change_moderation_action(%{}), as: :moderation)
           )
           |> put_flash(:info, message)}

        {:error, :forbidden} ->
          {:noreply,
           put_flash(socket, :error, "You do not have permission to moderate that member.")}

        {:error, :invalid_duration} ->
          changeset =
            Chat.change_moderation_action(params)
            |> Ecto.Changeset.add_error(:duration_minutes, "must be greater than zero")

          {:noreply, assign(socket, :member_action_form, to_form(changeset, as: :moderation))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not complete that moderation action.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to moderate members.")}
    end
  end

  defp assign_message_form(socket) do
    form =
      %Message{}
      |> Chat.change_message(%{body: ""})
      |> to_form(as: :message)

    assign(socket, :message_form, form)
  end

  defp assign_thread_message_form(socket) do
    form =
      %Message{}
      |> Chat.change_message(%{body: ""})
      |> to_form(as: :message)

    assign(socket, :thread_message_form, form)
  end

  defp load_channel(socket, channel) do
    messages = Chat.list_messages(channel.id)
    last_message = List.last(messages)
    Chat.mark_channel_read(socket.assigns.current_user, channel, last_message)
    thread_summaries = Chat.thread_summaries_for_channel(channel.id)

    refreshed_channels = Chat.list_channels_for_user(socket.assigns.current_user)
    refreshed_active_channel = Enum.find(refreshed_channels, &(&1.id == channel.id)) || channel

    active_thread =
      case socket.assigns.active_thread do
        %{} = thread ->
          Enum.find(Map.values(thread_summaries), &(&1.thread.id == thread.id))
          |> then(&(&1 && &1.thread))

        _ ->
          nil
      end

    socket
    |> assign(:channels, refreshed_channels)
    |> assign(:channel_sections, Chat.list_channel_tree_for_user(socket.assigns.current_user))
    |> assign(
      :all_channel_sections,
      SharedHelpers.channel_sections_for_manager(socket.assigns.can_manage_channels?)
    )
    |> assign(:mobile_sidebar_open?, false)
    |> assign(:mobile_members_open?, false)
    |> close_message_ui()
    |> assign(:active_channel, refreshed_active_channel)
    |> assign(:thread_summaries, thread_summaries)
    |> assign(
      :can_send_messages?,
      Chat.can_send_messages?(refreshed_active_channel, socket.assigns.current_user)
    )
    |> assign(
      :can_add_reactions?,
      Chat.can_add_reactions?(refreshed_active_channel, socket.assigns.current_user)
    )
    |> assign(
      :can_manage_messages?,
      Chat.can_manage_messages?(refreshed_active_channel, socket.assigns.current_user)
    )
    |> assign(
      :can_mention_everyone?,
      Chat.can_mention_everyone?(refreshed_active_channel, socket.assigns.current_user)
    )
    |> assign(
      :can_create_public_threads?,
      Chat.can_create_public_threads?(refreshed_active_channel, socket.assigns.current_user)
    )
    |> assign(:message_count, Chat.message_count(refreshed_active_channel.id))
    |> assign(:messages_empty?, messages == [])
    |> assign(
      :unread_counts,
      Chat.unread_counts_for_user(socket.assigns.current_user, refreshed_channels)
    )
    |> assign(
      :unread_mentions,
      Chat.unread_mentions_for_user(socket.assigns.current_user, refreshed_channels)
    )
    |> stream(:messages, messages, reset: true)
    |> maybe_restore_thread(active_thread)
  end

  defp redirect_to_default_channel(socket) do
    case List.first(socket.assigns.channels) do
      nil -> socket
      channel -> push_patch(socket, to: channel_path(channel))
    end
  end

  defp refresh_channels(socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels_for_user(current_user)

    active_channel =
      case socket.assigns.active_channel do
        nil -> nil
        active -> Enum.find(channels, &(&1.id == active.id))
      end

    socket
    |> assign(:channels, channels)
    |> assign(:channel_sections, Chat.list_channel_tree_for_user(current_user))
    |> assign(
      :all_channel_sections,
      SharedHelpers.channel_sections_for_manager(socket.assigns.can_manage_channels?)
    )
    |> assign(:active_channel, active_channel)
    |> close_message_ui()
    |> assign(
      :can_send_messages?,
      if(active_channel, do: Chat.can_send_messages?(active_channel, current_user), else: false)
    )
    |> assign(
      :can_add_reactions?,
      if(active_channel, do: Chat.can_add_reactions?(active_channel, current_user), else: false)
    )
    |> assign(
      :can_manage_messages?,
      if(active_channel, do: Chat.can_manage_messages?(active_channel, current_user), else: false)
    )
    |> assign(
      :can_mention_everyone?,
      if(active_channel,
        do: Chat.can_mention_everyone?(active_channel, current_user),
        else: false
      )
    )
    |> assign(
      :can_create_public_threads?,
      if(active_channel,
        do: Chat.can_create_public_threads?(active_channel, current_user),
        else: false
      )
    )
  end

  defp maybe_insert_message(socket, message) do
    active_channel = socket.assigns.active_channel

    cond do
      is_nil(active_channel) ->
        socket

      active_channel.id != message.channel_id ->
        socket

      not Chat.can_view_channel?(active_channel, socket.assigns.current_user) ->
        socket

      true ->
        Chat.mark_channel_read(socket.assigns.current_user, active_channel, message)

        socket
        |> assign(:messages_empty?, false)
        |> assign(:message_count, socket.assigns.message_count + 1)
        |> stream_insert(:messages, message)
    end
  end

  defp maybe_insert_thread_message(socket, message) do
    active_thread = socket.assigns.active_thread

    cond do
      is_nil(active_thread) ->
        socket

      active_thread.id != message.channel_id ->
        socket

      true ->
        Chat.mark_channel_read(socket.assigns.current_user, active_thread, message)
        starter_message_id = active_thread.starter_message_id

        socket
        |> assign(:thread_messages_empty?, false)
        |> assign(:thread_message_count, socket.assigns.thread_message_count + 1)
        |> stream_insert(:thread_messages, message)
        |> refresh_thread_summaries_for_active_channel()
        |> rerender_messages([starter_message_id])
    end
  end

  defp maybe_stream_update_message(socket, message) do
    if socket.assigns.active_channel && socket.assigns.active_channel.id == message.channel_id do
      stream_insert(socket, :messages, message)
    else
      socket
    end
  end

  defp maybe_stream_update_thread_message(socket, message) do
    if socket.assigns.active_thread && socket.assigns.active_thread.id == message.channel_id do
      socket
      |> stream_insert(:thread_messages, message)
      |> refresh_thread_summaries_for_active_channel()
      |> rerender_messages([socket.assigns.active_thread.starter_message_id])
    else
      socket
    end
  end

  defp maybe_refresh_thread_summaries(socket, channel) do
    active_channel = socket.assigns.active_channel

    cond do
      is_nil(active_channel) ->
        socket

      channel.parent_channel_id == active_channel.id ->
        socket
        |> refresh_thread_summaries_for_active_channel()
        |> rerender_messages([channel.starter_message_id])

      true ->
        socket
    end
  end

  defp refresh_unread_counts(socket) do
    assign(
      socket,
      :unread_counts,
      Chat.unread_counts_for_user(socket.assigns.current_user, socket.assigns.channels)
    )
  end

  defp refresh_unread_mentions(socket) do
    assign(
      socket,
      :unread_mentions,
      Chat.unread_mentions_for_user(socket.assigns.current_user, socket.assigns.channels)
    )
  end

  defp refresh_member_presence(socket) do
    assign(socket, :member_presence, Accounts.list_members_with_presence())
  end

  defp close_message_ui(socket) do
    socket
    |> assign(:reaction_picker_message_id, nil)
    |> assign(:active_message_controls_id, nil)
    |> assign(:message_action_menu_id, nil)
    |> assign(:delete_confirmation_message_id, nil)
  end

  defp rerender_messages(socket, message_ids) do
    Enum.reduce(Enum.reject(message_ids, &is_nil/1), socket, fn message_id, acc ->
      stream_insert(acc, :messages, Chat.get_message!(message_id))
    end)
  end

  defp rerender_active_thread_panel(socket) do
    case current_thread_starter_id(socket) do
      nil -> socket
      starter_message_id -> rerender_messages(socket, [starter_message_id])
    end
  end

  defp refresh_custom_emojis(socket) do
    current_user = socket.assigns.current_user

    socket
    |> assign(:custom_emojis, SharedHelpers.emoji_entries_for_picker(current_user))
    |> assign(:custom_emojis_json, emoji_entries_json_for_picker(current_user))
  end

  defp maybe_push_mention_notification(socket, message) do
    current_user = socket.assigns.current_user
    active_channel = socket.assigns.active_channel
    channel = Enum.find(socket.assigns.channels, &(&1.id == message.channel_id))

    cond do
      message.author_id == current_user.id ->
        socket

      active_channel && active_channel.id == message.channel_id ->
        socket

      is_nil(channel) ->
        socket

      not Chat.message_mentions_user?(message.id, current_user) ->
        socket

      not Chat.mention_notifications_enabled?(current_user, channel) ->
        socket

      true ->
        push_event(socket, "notify:mention", %{
          channel_id: message.channel_id,
          channel_name: channel && channel.name,
          author_name: message.author.display_name,
          body: message.body,
          message_id: message.id
        })
    end
  end

  defp refresh_thread_summaries_for_active_channel(socket) do
    case socket.assigns.active_channel do
      %{} = channel ->
        assign(socket, :thread_summaries, Chat.thread_summaries_for_channel(channel.id))

      nil ->
        assign(socket, :thread_summaries, %{})
    end
  end

  defp maybe_restore_thread(socket, nil), do: close_thread(socket)

  defp maybe_restore_thread(socket, thread) do
    open_thread(socket, thread, focus?: socket.assigns.thread_focus?)
  end

  defp open_thread(socket, thread, opts \\ []) do
    previous_starter_message_id = current_thread_starter_id(socket)
    thread_messages = Chat.list_thread_messages(thread.id)
    last_message = List.last(thread_messages)
    Chat.ensure_channel_memberships_for_user(socket.assigns.current_user, [thread])
    Chat.mark_channel_read(socket.assigns.current_user, thread, last_message)

    focus? = Keyword.get(opts, :focus?, false)

    socket
    |> assign(:active_thread, thread)
    |> assign(:thread_focus?, focus?)
    |> assign(:thread_reply_to_message, nil)
    |> assign(
      :can_send_thread_messages?,
      Chat.can_send_messages_in_threads?(thread, socket.assigns.current_user)
    )
    |> assign(:thread_message_count, Chat.message_count(thread.id))
    |> assign(:thread_messages_empty?, thread_messages == [])
    |> assign_thread_message_form()
    |> stream(:thread_messages, thread_messages, reset: true)
    |> rerender_messages([previous_starter_message_id, thread.starter_message_id])
  end

  defp close_thread(socket) do
    previous_starter_message_id = current_thread_starter_id(socket)

    socket
    |> assign(:active_thread, nil)
    |> assign(:thread_focus?, false)
    |> assign(:thread_reply_to_message, nil)
    |> assign(:can_send_thread_messages?, false)
    |> assign(:thread_message_count, 0)
    |> assign(:thread_messages_empty?, true)
    |> assign_thread_message_form()
    |> stream(:thread_messages, [], reset: true)
    |> rerender_messages([previous_starter_message_id])
  end

  defp current_thread_starter_id(socket) do
    case socket.assigns.active_thread do
      %{} = thread -> thread.starter_message_id
      _ -> nil
    end
  end

  defp channel_path(channel), do: ~p"/?channel=#{channel.slug}"

  defp thread_path(channel, thread), do: ~p"/?channel=#{channel.slug}&thread=#{thread.id}"

  defp channel_active?(nil, _channel), do: false
  defp channel_active?(active_channel, channel), do: active_channel.id == channel.id

  defp unread_count_for(channel, unread_counts) do
    Map.get(unread_counts, channel.id, 0)
  end

  defp unread_mentions_for(channel, unread_mentions) do
    Map.get(unread_mentions, channel.id, 0)
  end

  defp thread_summary_for(message, thread_summaries) do
    Map.get(thread_summaries, message.id)
  end

  defp thread_reply_count(message, thread_summaries) do
    case thread_summary_for(message, thread_summaries) do
      %{reply_count: count} -> count
      _ -> 0
    end
  end

  defp thread_for_message(message, thread_summaries) do
    case thread_summary_for(message, thread_summaries) do
      %{thread: thread} -> thread
      _ -> nil
    end
  end

  defp thread_open_for_message?(message, active_thread) do
    active_thread && active_thread.starter_message_id == message.id
  end

  defp thread_title(thread) do
    thread.name || "Thread"
  end

  defp save_channel(socket, channel_params) do
    attrs =
      SharedHelpers.normalize_channel_params(channel_params, socket.assigns.channel_form_mode)

    case socket.assigns.editing_channel_id do
      nil ->
        attrs = Map.put_new(attrs, "position", SharedHelpers.next_channel_position())

        case Chat.create_channel(attrs) do
          {:ok, channel} ->
            {:noreply,
             socket
             |> refresh_channels()
             |> SharedHelpers.assign_channel_form_mode(
               if(channel.kind == :category, do: :create_category, else: :create_text)
             )
             |> SharedHelpers.assign_channel_form()
             |> put_flash(:info, SharedHelpers.creation_flash(channel))}

          {:error, changeset} ->
            {:noreply, assign(socket, :channel_form, to_form(changeset, as: :channel))}
        end

      channel_id ->
        channel = Chat.get_channel!(channel_id)

        case Chat.update_channel(channel, attrs) do
          {:ok, updated_channel} ->
            {:noreply,
             socket
             |> refresh_channels()
             |> assign(:editing_channel_id, updated_channel.id)
             |> SharedHelpers.assign_channel_form_mode(
               SharedHelpers.edit_mode_for(updated_channel)
             )
             |> SharedHelpers.assign_channel_form(updated_channel)
             |> put_flash(:info, "Channel updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :channel_form, to_form(changeset, as: :channel))}
        end
    end
  end

  defp move_channel(channel_id, direction), do: SharedHelpers.move_channel(channel_id, direction)

  defp section_dom_id(nil), do: "channel-section-uncategorized"
  defp section_dom_id(category), do: "channel-section-#{category.slug}"

  # ARCHITECTURE NOTE: Stage A cleanup can still extract shared presentation helpers
  # like section_label/member_status_class/member_status_label/scrollbar_classes
  # into a dedicated Live UI helper module once we want to reduce duplicate view glue further.
  defp section_label(nil), do: "Text channels"
  defp section_label(category), do: category.name

  defp channel_kind_badge(:forum), do: "forum"
  defp channel_kind_badge(:announcement), do: "news"
  defp channel_kind_badge(:voice), do: "voice"
  defp channel_kind_badge(:stage), do: "stage"
  defp channel_kind_badge(_kind), do: "text"

  defp member_status_class(:online), do: "bg-emerald-400"
  defp member_status_class(:recent), do: "bg-amber-400"
  defp member_status_class(:offline), do: "bg-base-content/35"

  defp member_status_label(:online), do: "online"
  defp member_status_label(:recent), do: "recent"
  defp member_status_label(:offline), do: "offline"

  defp mobile_sidebar_class(true), do: "translate-x-0"
  defp mobile_sidebar_class(false), do: "-translate-x-full xl:translate-x-0"

  defp mobile_members_class(true), do: "translate-x-0"
  defp mobile_members_class(false), do: "translate-x-full xl:translate-x-0"

  defp mobile_sidebar_overlay_class(true), do: "opacity-100 pointer-events-auto"
  defp mobile_sidebar_overlay_class(false), do: "pointer-events-none opacity-0"

  defp scrollbar_classes do
    [
      "[scrollbar-width:thin]",
      "[scrollbar-color:rgba(255,255,255,0.12)_transparent]",
      "[&::-webkit-scrollbar]:h-2.5",
      "[&::-webkit-scrollbar]:w-2.5",
      "[&::-webkit-scrollbar-track]:bg-transparent",
      "[&::-webkit-scrollbar-thumb]:rounded-full",
      "[&::-webkit-scrollbar-thumb]:border-2",
      "[&::-webkit-scrollbar-thumb]:border-transparent",
      "[&::-webkit-scrollbar-thumb]:bg-[rgba(255,255,255,0.12)]",
      "[&::-webkit-scrollbar-thumb]:bg-clip-padding",
      "[&::-webkit-scrollbar-thumb:hover]:bg-[rgba(255,255,255,0.2)]"
    ]
    |> Enum.join(" ")
  end

  defp composer_shell_classes do
    "flex min-w-0 flex-1 flex-col gap-2"
  end

  defp composer_toolbar_region_classes do
    [
      "grid gap-[0.45rem] max-h-0 overflow-hidden opacity-0 pointer-events-none -translate-y-1",
      "transition-[max-height,opacity,transform] duration-200 ease-out",
      "data-[expanded=true]:max-h-24 data-[expanded=true]:translate-y-0",
      "data-[expanded=true]:opacity-100 data-[expanded=true]:pointer-events-auto"
    ]
    |> Enum.join(" ")
  end

  defp composer_toolbar_button_classes do
    [
      "inline-flex min-h-[1.9rem] min-w-[1.9rem] items-center justify-center rounded-lg border",
      "border-base-300 bg-base-100 px-[0.2rem] text-[11px] font-bold text-base-content/70 transition",
      "hover:border-primary/40 hover:bg-primary/10 hover:text-primary",
      "data-[active=true]:border-primary/40 data-[active=true]:bg-primary/10",
      "data-[active=true]:text-primary"
    ]
    |> Enum.join(" ")
  end

  defp message_body_classes do
    [
      "mt-0.5 break-words text-[15px] leading-6 text-base-content",
      "[&>p]:m-0 [&>ul]:m-0 [&>ul]:pl-5 [&>ol]:m-0 [&>ol]:pl-5",
      "[&_li+li]:mt-0.5 [&>p+p]:mt-[0.55rem] [&>p+ul]:mt-[0.55rem] [&>p+ol]:mt-[0.55rem]",
      "[&>ul+p]:mt-[0.55rem] [&>ol+p]:mt-[0.55rem] [&_.message-code-block]:mt-[0.55rem]",
      "[&_.message-link-embed]:mt-[0.55rem]"
    ]
    |> Enum.join(" ")
  end

  defp reaction_summaries(message, current_user) do
    message.reactions
    |> Enum.group_by(fn reaction ->
      if reaction.emoji_id,
        do: {:custom, reaction.emoji_id},
        else: {:unicode, reaction.emoji_unicode}
    end)
    |> Enum.map(fn
      {{:custom, emoji_id}, reactions} ->
        reaction = List.first(reactions)

        %{
          kind: :custom,
          emoji_id: emoji_id,
          emoji_unicode: nil,
          label: reaction.emoji && reaction.emoji.name,
          url: reaction.emoji && reaction.emoji.asset && Chat.asset_url(reaction.emoji.asset),
          count: length(reactions),
          reacted?: Enum.any?(reactions, &(&1.user_id == current_user.id))
        }

      {{:unicode, emoji_unicode}, reactions} ->
        %{
          kind: :unicode,
          emoji_id: nil,
          emoji_unicode: emoji_unicode,
          label: emoji_unicode,
          url: nil,
          count: length(reactions),
          reacted?: Enum.any?(reactions, &(&1.user_id == current_user.id))
        }
    end)
    |> Enum.sort_by(fn summary ->
      case summary.kind do
        :unicode -> {0, summary.label}
        :custom -> {1, summary.label || ""}
      end
    end)
  end

  defp reaction_picker_open?(message, reaction_picker_message_id) do
    reaction_picker_message_id == message.id
  end

  defp emoji_entries_json_for_picker(current_user) do
    Jason.encode!(%{
      custom: SharedHelpers.emoji_entries_for_picker(current_user),
      branding: SharedHelpers.server_branding()
    })
  end

  defp save_emoji(socket, emoji_params) do
    SharedHelpers.save_emoji(socket, emoji_params, &refresh_custom_emojis/1)
  end

  defp maybe_put_reply(socket, message_params) do
    case socket.assigns.reply_to_message do
      nil -> message_params
      reply_to_message -> Map.put(message_params, "reply_to_id", reply_to_message.id)
    end
  end

  defp maybe_put_thread_reply(socket, message_params) do
    case socket.assigns.thread_reply_to_message do
      nil -> message_params
      reply_to_message -> Map.put(message_params, "reply_to_id", reply_to_message.id)
    end
  end

  defp clear_reply_to_message(socket), do: assign(socket, :reply_to_message, nil)

  defp own_message?(message, current_user), do: message.author_id == current_user.id

  defp normalize_message_id(message_id), do: message_id

  defp message_controls_visible?(message_id, active_message_controls_id, message_action_menu_id) do
    active_message_controls_id == message_id or message_action_menu_id == message_id
  end

  defp message_action_menu_open?(message_id, message_action_menu_id) do
    message_action_menu_id == message_id
  end

  defp delete_confirmation_open?(message_id, delete_confirmation_message_id) do
    delete_confirmation_message_id == message_id
  end

  defp can_open_message_controls?(message, current_user, can_send_messages?, can_manage_messages?) do
    not deleted_message?(message) and
      (can_send_messages? or own_message?(message, current_user) or can_manage_messages?)
  end

  defp run_member_moderation(actor, subject, params),
    do: SharedHelpers.run_member_moderation(actor, subject, params)

  defp deleted_message?(message) do
    not is_nil(message.deleted_at) or Map.get(message.metadata || %{}, "deleted", false)
  end

  defp edited_message?(message),
    do: not is_nil(message.edited_at) and not deleted_message?(message)
end
