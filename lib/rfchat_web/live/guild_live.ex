defmodule RfchatWeb.GuildLive do
  use RfchatWeb, :live_view

  alias Rfchat.Accounts
  alias Rfchat.Chat
  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.Message

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels_for_user(current_user)
    :ok = Chat.ensure_channel_memberships_for_user(current_user, channels)
    can_manage_channels? = can_manage_channels?(socket.assigns.current_scope)

    if connected?(socket) do
      Chat.subscribe_to_channel_events()
    end

    socket =
      socket
      |> assign(:guild_name, Application.get_env(:rfchat, :guild_name, "RFChat"))
      |> assign(:current_user, current_user)
      |> assign(:can_manage_channels?, can_manage_channels?)
      |> assign(:channels, channels)
      |> assign(:channel_sections, Chat.list_channel_tree_for_user(current_user))
      |> assign(:all_channel_sections, channel_sections_for_manager(can_manage_channels?))
      |> assign(:member_presence, Accounts.list_members_with_presence())
      |> assign(:notification_setting, Chat.get_user_notification_setting(current_user))
      |> assign(:composer_mentions_json, Jason.encode!(Chat.composer_mentions()))
      |> assign(:composer_commands_json, Jason.encode!(Chat.composer_slash_commands()))
      |> assign(:unread_counts, Chat.unread_counts_for_user(current_user, channels))
      |> assign(:unread_mentions, Chat.unread_mentions_for_user(current_user, channels))
      |> assign(:mobile_sidebar_open?, false)
      |> assign(:manage_channels_open?, false)
      |> assign(:active_channel, nil)
      |> assign(:can_send_messages?, false)
      |> assign(:can_add_reactions?, false)
      |> assign(:can_manage_messages?, false)
      |> assign(:can_mention_everyone?, false)
      |> assign(:reply_to_message, nil)
      |> assign(:editing_message_id, nil)
      |> assign(:editing_form, nil)
      |> assign(:channel_form_mode, :create_text)
      |> assign(:channel_form_title, "Create text channel")
      |> assign(:editing_channel_id, nil)
      |> assign(:message_count, 0)
      |> assign(:messages_empty?, true)
      |> assign_message_form()
      |> assign_channel_form()
      |> stream(:messages, [], reset: true)

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
  def handle_params(%{"channel" => slug}, _uri, socket) do
    case Chat.get_channel_by_slug_for_user(slug, socket.assigns.current_user) do
      {:ok, channel} ->
        {:noreply, load_channel(socket, channel)}

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
      |> maybe_push_mention_notification(message)

    {:noreply,
     socket
     |> refresh_unread_counts()
     |> refresh_unread_mentions()
     |> refresh_member_presence()}
  end

  @impl true
  def handle_info({:message_updated, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  @impl true
  def handle_info({:message_deleted, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
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
    {:noreply, assign(socket, :mobile_sidebar_open?, !socket.assigns.mobile_sidebar_open?)}
  end

  @impl true
  def handle_event("close_mobile_sidebar", _params, socket) do
    {:noreply, assign(socket, :mobile_sidebar_open?, false)}
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
  def handle_event("new_channel_form", %{"mode" => mode}, socket) do
    if socket.assigns.can_manage_channels? do
      {:noreply, socket |> assign_channel_form_mode(mode) |> assign_channel_form()}
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
       |> assign_channel_form_mode(edit_mode_for(channel))
       |> assign_channel_form(channel)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("cancel_channel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_channel_id, nil)
     |> assign_channel_form_mode(:create_text)
     |> assign_channel_form()}
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
            |> assign_channel_form_mode(:create_text)
            |> assign_channel_form()
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

            socket = push_event(socket, "composer:clear", %{})

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
  def handle_event("reply_message", %{"id" => message_id}, socket) do
    {:noreply, assign(socket, :reply_to_message, Chat.get_message!(message_id))}
  end

  @impl true
  def handle_event("cancel_reply", _params, socket) do
    {:noreply, clear_reply_to_message(socket)}
  end

  @impl true
  def handle_event("edit_message", %{"id" => message_id}, socket) do
    message = Chat.get_message!(message_id)

    if message.author_id == socket.assigns.current_user.id do
      form = message |> Chat.change_message(%{body: message.body}) |> to_form(as: :message)

      {:noreply,
       socket
       |> assign(:editing_message_id, message.id)
       |> assign(:editing_form, form)
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
    message = Chat.get_message!(message_id)

    case Chat.delete_message(message, socket.assigns.current_user) do
      {:ok, deleted_message} ->
        {:noreply,
         socket
         |> assign(:editing_message_id, nil)
         |> assign(:editing_form, nil)
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
        {:noreply, stream_insert(socket, :messages, updated_message)}

      {:error, :invalid_emoji} ->
        {:noreply, put_flash(socket, :error, "Choose a valid reaction.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to add reactions here.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not toggle that reaction.")}
    end
  end

  defp assign_message_form(socket) do
    form =
      %Message{}
      |> Chat.change_message(%{body: ""})
      |> to_form(as: :message)

    assign(socket, :message_form, form)
  end

  defp assign_channel_form(socket, channel \\ nil) do
    channel = channel || %Chat.Channel{}

    attrs =
      if channel.id do
        %{
          name: channel.name,
          slug: channel.slug,
          topic: channel.topic,
          kind: channel.kind,
          parent_channel_id: channel.parent_channel_id,
          nsfw: channel.nsfw
        }
      else
        default_channel_attrs(socket.assigns.channel_form_mode)
      end

    form =
      channel
      |> Chat.change_channel(attrs)
      |> to_form(as: :channel)

    socket
    |> assign(:channel_form, form)
    |> assign(:editing_channel_id, channel.id)
  end

  defp load_channel(socket, channel) do
    messages = Chat.list_messages(channel.id)
    last_message = List.last(messages)
    Chat.mark_channel_read(socket.assigns.current_user, channel, last_message)

    refreshed_channels = Chat.list_channels_for_user(socket.assigns.current_user)
    refreshed_active_channel = Enum.find(refreshed_channels, &(&1.id == channel.id)) || channel

    socket
    |> assign(:channels, refreshed_channels)
    |> assign(:channel_sections, Chat.list_channel_tree_for_user(socket.assigns.current_user))
    |> assign(
      :all_channel_sections,
      channel_sections_for_manager(socket.assigns.can_manage_channels?)
    )
    |> assign(:mobile_sidebar_open?, false)
    |> assign(:active_channel, refreshed_active_channel)
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
      channel_sections_for_manager(socket.assigns.can_manage_channels?)
    )
    |> assign(:active_channel, active_channel)
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

  defp channel_path(channel), do: ~p"/?channel=#{channel.slug}"

  defp channel_active?(nil, _channel), do: false
  defp channel_active?(active_channel, channel), do: active_channel.id == channel.id

  defp unread_count_for(channel, unread_counts) do
    Map.get(unread_counts, channel.id, 0)
  end

  defp unread_mentions_for(channel, unread_mentions) do
    Map.get(unread_mentions, channel.id, 0)
  end

  defp mention_alerts_enabled?(setting) do
    setting.desktop_enabled && setting.notify_on_mentions
  end

  defp can_manage_channels?(nil), do: false

  defp can_manage_channels?(scope) do
    permissions = scope_permissions(scope)

    Authorization.has_permission?(permissions, :manage_channels) or
      Authorization.has_permission?(permissions, :administrator)
  end

  defp scope_permissions(%{
         base_permissions: base_permissions,
         membership: membership,
         roles: roles
       }) do
    role_permissions = Enum.reduce(roles || [], 0, &Bitwise.bor(&1.permissions, &2))

    cond do
      membership && membership.is_owner ->
        Authorization.all_permissions()

      Authorization.has_permission?(base_permissions || 0, :administrator) ->
        Authorization.all_permissions()

      Authorization.has_permission?(role_permissions, :administrator) ->
        Authorization.all_permissions()

      true ->
        Bitwise.bor(base_permissions || 0, role_permissions)
    end
  end

  defp channel_sections_for_manager(true), do: Chat.list_channel_tree()
  defp channel_sections_for_manager(false), do: []

  defp assign_channel_form_mode(socket, mode) when is_binary(mode) do
    assign_channel_form_mode(socket, String.to_existing_atom(mode))
  rescue
    ArgumentError -> assign_channel_form_mode(socket, :create_text)
  end

  defp assign_channel_form_mode(socket, :create_category) do
    socket
    |> assign(:channel_form_mode, :create_category)
    |> assign(:channel_form_title, "Create category")
    |> assign(:editing_channel_id, nil)
  end

  defp assign_channel_form_mode(socket, :edit_category) do
    socket
    |> assign(:channel_form_mode, :edit_category)
    |> assign(:channel_form_title, "Edit category")
  end

  defp assign_channel_form_mode(socket, :edit_text) do
    socket
    |> assign(:channel_form_mode, :edit_text)
    |> assign(:channel_form_title, "Edit channel")
  end

  defp assign_channel_form_mode(socket, _mode) do
    socket
    |> assign(:channel_form_mode, :create_text)
    |> assign(:channel_form_title, "Create text channel")
    |> assign(:editing_channel_id, nil)
  end

  defp default_channel_attrs(:create_category) do
    %{kind: :category, name: "", slug: "", topic: nil, parent_channel_id: nil, nsfw: false}
  end

  defp default_channel_attrs(_mode) do
    %{kind: :text, name: "", slug: "", topic: nil, parent_channel_id: nil, nsfw: false}
  end

  defp edit_mode_for(channel) do
    if channel.kind == :category, do: :edit_category, else: :edit_text
  end

  defp save_channel(socket, channel_params) do
    attrs = normalize_channel_params(channel_params, socket)

    case socket.assigns.editing_channel_id do
      nil ->
        attrs = Map.put_new(attrs, "position", next_channel_position())

        case Chat.create_channel(attrs) do
          {:ok, channel} ->
            {:noreply,
             socket
             |> refresh_channels()
             |> assign_channel_form_mode(
               if(channel.kind == :category, do: :create_category, else: :create_text)
             )
             |> assign_channel_form()
             |> put_flash(:info, creation_flash(channel))}

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
             |> assign_channel_form_mode(edit_mode_for(updated_channel))
             |> assign_channel_form(updated_channel)
             |> put_flash(:info, "Channel updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :channel_form, to_form(changeset, as: :channel))}
        end
    end
  end

  defp creation_flash(channel) do
    if channel.kind == :category, do: "Category created.", else: "Channel created."
  end

  defp normalize_channel_params(channel_params, socket) do
    mode = socket.assigns.channel_form_mode
    kind = if mode in [:create_category, :edit_category], do: "category", else: "text"

    channel_params
    |> Map.put("kind", kind)
    |> Map.update("parent_channel_id", nil, fn parent_id ->
      if kind == "category", do: nil, else: blank_to_nil(parent_id)
    end)
    |> Map.update("topic", nil, &blank_to_nil/1)
    |> Map.update("slug", "", fn slug ->
      slug = String.trim(slug || "")
      if slug == "", do: slugify(Map.get(channel_params, "name", "")), else: slug
    end)
  end

  defp next_channel_position do
    Chat.list_channels()
    |> Enum.map(& &1.position)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  defp move_channel(channel_id, direction) do
    sections = Chat.list_channel_tree()

    case swap_in_sections(sections, channel_id, direction) do
      {:ok, updated_sections} ->
        case Chat.reorder_channels(updated_sections) do
          {:ok, _channels} -> :ok
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp swap_in_sections(sections, channel_id, direction) do
    Enum.reduce_while(Enum.with_index(sections), :error, fn {section, section_index}, _acc ->
      ids = Enum.map(section.channels, & &1.id)

      case Enum.find_index(ids, &(&1 == channel_id)) do
        nil ->
          {:cont, :error}

        index ->
          target_index = if direction == "up", do: index - 1, else: index + 1

          if target_index < 0 or target_index >= length(ids) do
            {:halt, :error}
          else
            updated_ids = swap_positions(ids, index, target_index)

            updated_sections =
              List.update_at(sections, section_index, fn current_section ->
                %{current_section | channels: updated_ids}
              end)

            {:halt, {:ok, serialize_sections(updated_sections)}}
          end
      end
    end)
  end

  defp serialize_sections(sections) do
    Enum.map(sections, fn section ->
      %{
        category: section.category && section.category.id,
        channels:
          Enum.map(section.channels, fn channel ->
            if is_binary(channel), do: channel, else: channel.id
          end)
      }
    end)
  end

  defp swap_positions(list, left, right) do
    left_value = Enum.at(list, left)
    right_value = Enum.at(list, right)

    list
    |> List.replace_at(left, right_value)
    |> List.replace_at(right, left_value)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp manageable_categories(sections) do
    sections
    |> Enum.map(& &1.category)
    |> Enum.reject(&is_nil/1)
  end

  defp section_dom_id(nil), do: "channel-section-uncategorized"
  defp section_dom_id(category), do: "channel-section-#{category.slug}"

  defp section_label(nil), do: "Text channels"
  defp section_label(category), do: category.name

  defp channel_kind_badge(:forum), do: "forum"
  defp channel_kind_badge(:announcement), do: "news"
  defp channel_kind_badge(:voice), do: "voice"
  defp channel_kind_badge(:stage), do: "stage"
  defp channel_kind_badge(_kind), do: "text"

  defp member_status_class(:online), do: "bg-emerald-400"
  defp member_status_class(:recent), do: "bg-amber-400"
  defp member_status_class(:offline), do: "bg-zinc-600"

  defp member_status_label(:online), do: "online"
  defp member_status_label(:recent), do: "recent"
  defp member_status_label(:offline), do: "offline"

  defp mobile_sidebar_class(true), do: "translate-x-0"
  defp mobile_sidebar_class(false), do: "-translate-x-full xl:translate-x-0"

  defp mobile_sidebar_overlay_class(true), do: "opacity-100 pointer-events-auto"
  defp mobile_sidebar_overlay_class(false), do: "pointer-events-none opacity-0"

  defp reaction_count(message, emoji_unicode) do
    message.reactions
    |> Enum.count(&(&1.emoji_unicode == emoji_unicode))
  end

  defp reacted_by_current_user?(message, current_user, emoji_unicode) do
    Enum.any?(message.reactions, fn reaction ->
      reaction.user_id == current_user.id and reaction.emoji_unicode == emoji_unicode
    end)
  end

  defp maybe_put_reply(socket, message_params) do
    case socket.assigns.reply_to_message do
      nil -> message_params
      reply_to_message -> Map.put(message_params, "reply_to_id", reply_to_message.id)
    end
  end

  defp clear_reply_to_message(socket), do: assign(socket, :reply_to_message, nil)

  defp own_message?(message, current_user), do: message.author_id == current_user.id

  defp deleted_message?(message) do
    not is_nil(message.deleted_at) or Map.get(message.metadata || %{}, "deleted", false)
  end

  defp edited_message?(message),
    do: not is_nil(message.edited_at) and not deleted_message?(message)
end
