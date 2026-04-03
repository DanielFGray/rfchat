defmodule RfchatWeb.GuildLive.State do
  @moduledoc false

  use RfchatWeb, :html

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  import Phoenix.LiveView,
    only: [push_event: 3, push_patch: 2, stream: 4, stream_insert: 3]

  alias Rfchat.Accounts
  alias Rfchat.Chat
  alias Rfchat.Chat.Message

  def assign_message_form(socket) do
    form =
      %Message{}
      |> Chat.change_message(%{body: ""})
      |> to_form(as: :message)

    assign(socket, :message_form, form)
  end

  def assign_thread_message_form(socket) do
    form =
      %Message{}
      |> Chat.change_message(%{body: ""})
      |> to_form(as: :message)

    assign(socket, :thread_message_form, form)
  end

  def load_channel(socket, channel) do
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

  def redirect_to_default_channel(socket) do
    case List.first(socket.assigns.channels) do
      nil -> socket
      channel -> push_patch(socket, to: channel_path(channel))
    end
  end

  def refresh_channels(socket) do
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

  def maybe_insert_message(socket, message) do
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

  def maybe_insert_thread_message(socket, message) do
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

  def maybe_stream_update_message(socket, message) do
    if socket.assigns.active_channel && socket.assigns.active_channel.id == message.channel_id do
      stream_insert(socket, :messages, message)
    else
      socket
    end
  end

  def maybe_stream_update_thread_message(socket, message) do
    if socket.assigns.active_thread && socket.assigns.active_thread.id == message.channel_id do
      socket
      |> stream_insert(:thread_messages, message)
      |> refresh_thread_summaries_for_active_channel()
      |> rerender_messages([socket.assigns.active_thread.starter_message_id])
    else
      socket
    end
  end

  def maybe_refresh_thread_summaries(socket, channel) do
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

  def refresh_unread_counts(socket) do
    assign(
      socket,
      :unread_counts,
      Chat.unread_counts_for_user(socket.assigns.current_user, socket.assigns.channels)
    )
  end

  def refresh_unread_mentions(socket) do
    assign(
      socket,
      :unread_mentions,
      Chat.unread_mentions_for_user(socket.assigns.current_user, socket.assigns.channels)
    )
  end

  def refresh_member_presence(socket) do
    assign(socket, :member_presence, Accounts.list_members_with_presence())
  end

  def close_message_ui(socket) do
    socket
    |> assign(:reaction_picker_message_id, nil)
    |> assign(:active_message_controls_id, nil)
    |> assign(:message_action_menu_id, nil)
    |> assign(:delete_confirmation_message_id, nil)
  end

  def rerender_messages(socket, message_ids) do
    Enum.reduce(Enum.reject(message_ids, &is_nil/1), socket, fn message_id, acc ->
      stream_insert(acc, :messages, Chat.get_message!(message_id))
    end)
  end

  def rerender_active_thread_panel(socket) do
    case current_thread_starter_id(socket) do
      nil -> socket
      starter_message_id -> rerender_messages(socket, [starter_message_id])
    end
  end

  def maybe_push_mention_notification(socket, message) do
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

  def refresh_thread_summaries_for_active_channel(socket) do
    case socket.assigns.active_channel do
      %{} = channel ->
        assign(socket, :thread_summaries, Chat.thread_summaries_for_channel(channel.id))

      nil ->
        assign(socket, :thread_summaries, %{})
    end
  end

  def maybe_restore_thread(socket, nil), do: close_thread(socket)

  def maybe_restore_thread(socket, thread) do
    open_thread(socket, thread, focus?: socket.assigns.thread_focus?)
  end

  def open_thread(socket, thread, opts \\ []) do
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

  def close_thread(socket) do
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

  def current_thread_starter_id(socket) do
    case socket.assigns.active_thread do
      %{} = thread -> thread.starter_message_id
      _ -> nil
    end
  end

  def maybe_put_reply(socket, message_params) do
    case socket.assigns.reply_to_message do
      nil -> message_params
      reply_to_message -> Map.put(message_params, "reply_to_id", reply_to_message.id)
    end
  end

  def maybe_put_thread_reply(socket, message_params) do
    case socket.assigns.thread_reply_to_message do
      nil -> message_params
      reply_to_message -> Map.put(message_params, "reply_to_id", reply_to_message.id)
    end
  end

  def clear_reply_to_message(socket), do: assign(socket, :reply_to_message, nil)

  defp channel_path(channel), do: ~p"/?channel=#{channel.slug}"
end
