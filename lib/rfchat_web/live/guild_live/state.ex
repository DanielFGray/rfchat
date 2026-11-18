defmodule RfchatWeb.GuildLive.State do
  @moduledoc false

  use RfchatWeb, :html

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  import Phoenix.LiveView,
    only: [connected?: 1, push_event: 3, push_patch: 2, stream: 4, stream_insert: 3]

  alias Rfchat.Accounts
  alias Rfchat.Chat
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.Topics

  def queue_initial_hydration(socket) do
    if connected?(socket) do
      send(self(), :hydrate_navigation)
      send(self(), :hydrate_members)
      socket
    else
      socket
    end
  end

  def queue_channel_hydration(socket) do
    case socket.assigns.active_channel do
      %{} = channel ->
        channel_request_token = System.unique_integer([:positive])
        send(self(), {:hydrate_channel, channel.id, channel_request_token})
        assign(socket, :channel_request_token, channel_request_token)

      nil ->
        socket
    end
  end

  def hydrate_navigation(socket) do
    visible_channels = Chat.list_channels(socket.assigns.current_scope)
    channels = Enum.filter(visible_channels, &visible_text_channel?/1)
    :ok = Chat.ensure_channel_memberships(socket.assigns.current_scope, channels)

    socket
    |> assign(:channels, channels)
    |> assign(:channel_sections, Chat.build_channel_tree(visible_channels))
    |> assign(:navigation_ready?, true)
    |> sync_active_channel(channels)
    |> sync_channel_subscriptions()
  end

  @doc """
  Subscribes the socket to the topics of its listed channels, the active channel and the active
  thread, and unsubscribes it from all other channel topics.

  The subscription set is the only filter between channel events and this socket, so each
  function that changes `:channels`, `:active_channel` or `:active_thread` calls this.
  """
  def sync_channel_subscriptions(socket) do
    if connected?(socket) do
      %{channels: channels, active_channel: active_channel, active_thread: active_thread} =
        socket.assigns

      wanted =
        [active_channel, active_thread | channels]
        |> Enum.reject(&is_nil/1)
        |> MapSet.new(& &1.id)

      assign(
        socket,
        :subscribed_channel_ids,
        Topics.sync_channel_subscriptions(socket.assigns.subscribed_channel_ids, wanted)
      )
    else
      socket
    end
  end

  def hydrate_unread_state(socket) do
    socket
    |> refresh_unread_counts()
    |> refresh_unread_mentions()
  end

  def hydrate_members(socket) do
    socket
    |> assign(:member_presence, Accounts.list_members(socket.assigns.current_scope))
    |> assign(:members_ready?, true)
  end

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

  def load_channel(socket, channel, opts \\ []) do
    messages =
      case Chat.list_messages(socket.assigns.current_scope, channel.id) do
        {:ok, messages} -> messages
        {:error, :not_found} -> []
      end

    last_message = List.last(messages)
    Chat.mark_channel_read(socket.assigns.current_user, channel, last_message)
    thread_summaries = Chat.thread_summaries_for_channel(socket.assigns.current_scope, channel.id)

    visible_channels = Keyword.get(opts, :visible_channels)
    refreshed_channels = Keyword.get(opts, :channels)

    visible_channels =
      visible_channels || Chat.list_channels(socket.assigns.current_scope)

    refreshed_channels =
      refreshed_channels || Enum.filter(visible_channels, &visible_text_channel?/1)

    refreshed_active_channel = Enum.find(refreshed_channels, &(&1.id == channel.id)) || channel

    unread_counts =
      Keyword.get(opts, :unread_counts) ||
        Chat.unread_counts_for_user(socket.assigns.current_user, refreshed_channels)

    unread_mentions =
      Keyword.get(opts, :unread_mentions) ||
        Chat.unread_mentions_for_user(socket.assigns.current_user, refreshed_channels)

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
    |> assign(:channel_sections, Chat.build_channel_tree(visible_channels))
    |> assign(:navigation_ready?, true)
    |> assign(:mobile_sidebar_open?, false)
    |> assign(:mobile_members_open?, false)
    |> close_message_ui()
    |> assign(:active_channel, refreshed_active_channel)
    |> assign(:thread_summaries, thread_summaries)
    |> assign(
      :typing_users,
      Chat.list_typing_users(socket.assigns.current_scope, refreshed_active_channel.id)
    )
    |> assign(:channel_ready?, true)
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
    |> assign(
      :message_count,
      Chat.message_count(socket.assigns.current_scope, refreshed_active_channel.id)
    )
    |> assign(:messages_empty?, messages == [])
    |> assign(:unread_counts, unread_counts)
    |> assign(:unread_mentions, unread_mentions)
    |> stream(:messages, messages, reset: true)
    |> sync_channel_subscriptions()
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
    visible_channels = Chat.list_channels(socket.assigns.current_scope)
    channels = Enum.filter(visible_channels, &visible_text_channel?/1)

    active_channel =
      case socket.assigns.active_channel do
        nil -> nil
        active -> Enum.find(channels, &(&1.id == active.id))
      end

    socket
    |> assign(:channels, channels)
    |> assign(:channel_sections, Chat.build_channel_tree(visible_channels))
    |> assign(:navigation_ready?, true)
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
    |> sync_channel_subscriptions()
  end

  def maybe_insert_message(socket, message) do
    active_channel = socket.assigns.active_channel

    cond do
      is_nil(active_channel) ->
        socket

      active_channel.id != message.channel_id ->
        socket

      not socket.assigns.channel_ready? ->
        socket

      true ->
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

      not socket.assigns.channel_ready? ->
        socket

      true ->
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
    socket
    |> assign(:member_presence, Accounts.list_members(socket.assigns.current_scope))
    |> assign(:members_ready?, true)
  end

  def close_message_ui(socket) do
    socket
    |> assign(:reaction_picker_message_id, nil)
    |> assign(:active_message_controls_id, nil)
    |> assign(:message_action_menu_id, nil)
    |> assign(:delete_confirmation_message_id, nil)
  end

  @doc """
  The message a client event names, when it belongs to the channel or thread the user has open.
  The client can send any id, and the open conversation is one the user can view, so a message
  event acts only on a message found here.
  """
  def fetch_open_message(socket, message_id) do
    open_ids =
      [socket.assigns.active_channel, socket.assigns[:active_thread]]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)

    with %Message{} = message <- Chat.get_message(socket.assigns.current_scope, message_id),
         true <- message.channel_id in open_ids do
      {:ok, message}
    else
      _ -> :error
    end
  end

  # The :messages stream lists the open channel, so only its messages are inserted.
  def rerender_messages(socket, message_ids) do
    channel_ids =
      if socket.assigns.active_channel, do: [socket.assigns.active_channel.id], else: []

    socket.assigns.current_scope
    |> Chat.get_messages(message_ids)
    |> Enum.reduce(socket, fn %Message{channel_id: channel_id} = message, acc ->
      if channel_id in channel_ids, do: stream_insert(acc, :messages, message), else: acc
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

      not Chat.message_mentions_user?(message, current_user) ->
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
        assign(
          socket,
          :thread_summaries,
          Chat.thread_summaries_for_channel(socket.assigns.current_scope, channel.id)
        )

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

    # Subscribe before listing, so a message posted between the two is not lost.
    socket =
      socket
      |> assign(:active_thread, thread)
      |> sync_channel_subscriptions()

    thread_messages =
      case Chat.list_messages(socket.assigns.current_scope, thread.id) do
        {:ok, messages} -> messages
        _ -> []
      end

    last_message = List.last(thread_messages)
    Chat.ensure_channel_memberships(socket.assigns.current_scope, [thread])
    Chat.mark_channel_read(socket.assigns.current_user, thread, last_message)

    focus? = Keyword.get(opts, :focus?, false)

    socket
    |> assign(:thread_focus?, focus?)
    |> assign(
      :thread_typing_users,
      Chat.list_typing_users(socket.assigns.current_scope, thread.id)
    )
    |> assign(:thread_reply_to_message, nil)
    |> assign(
      :can_send_thread_messages?,
      Chat.can_send_messages_in_threads?(thread, socket.assigns.current_user)
    )
    |> assign(:thread_message_count, Chat.message_count(socket.assigns.current_scope, thread.id))
    |> assign(:thread_messages_empty?, thread_messages == [])
    |> assign_thread_message_form()
    |> stream(:thread_messages, thread_messages, reset: true)
    |> rerender_messages([previous_starter_message_id, thread.starter_message_id])
  end

  def close_thread(socket) do
    previous_starter_message_id = current_thread_starter_id(socket)

    case socket.assigns.active_thread do
      %{} = thread ->
        Chat.clear_typing(socket.assigns.current_scope, thread.id)

      nil ->
        :ok
    end

    socket
    |> assign(:active_thread, nil)
    |> assign(:thread_focus?, false)
    |> assign(:thread_typing_users, [])
    |> assign(:thread_reply_to_message, nil)
    |> assign(:can_send_thread_messages?, false)
    |> assign(:thread_message_count, 0)
    |> assign(:thread_messages_empty?, true)
    |> assign_thread_message_form()
    |> stream(:thread_messages, [], reset: true)
    |> rerender_messages([previous_starter_message_id])
    |> sync_channel_subscriptions()
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

  def hydrate_channel_stale?(socket, channel_id, channel_request_token) do
    socket.assigns.channel_request_token != channel_request_token or
      is_nil(socket.assigns.active_channel) or socket.assigns.active_channel.id != channel_id
  end

  def set_channel_loading(socket, channel) do
    socket
    |> close_message_ui()
    |> assign(:active_channel, channel)
    |> assign(:channel_ready?, false)
    |> assign(:can_send_messages?, false)
    |> assign(:can_add_reactions?, false)
    |> assign(:can_manage_messages?, false)
    |> assign(:can_mention_everyone?, false)
    |> assign(:can_create_public_threads?, false)
    |> assign(:reply_to_message, nil)
    |> assign(:editing_message_id, nil)
    |> assign(:editing_form, nil)
    |> assign(:message_count, 0)
    |> assign(:messages_empty?, true)
    |> assign(:thread_summaries, %{})
    |> assign(:typing_users, [])
    |> close_thread()
    |> stream(:messages, [], reset: true)
    |> sync_channel_subscriptions()
  end

  def refresh_typing_users(socket) do
    case socket.assigns.active_channel do
      %{} = channel ->
        assign(
          socket,
          :typing_users,
          Chat.list_typing_users(socket.assigns.current_scope, channel.id)
        )

      nil ->
        assign(socket, :typing_users, [])
    end
  end

  def refresh_thread_typing_users(socket) do
    case socket.assigns.active_thread do
      %{} = thread ->
        assign(
          socket,
          :thread_typing_users,
          Chat.list_typing_users(socket.assigns.current_scope, thread.id)
        )

      nil ->
        assign(socket, :thread_typing_users, [])
    end
  end

  defp sync_active_channel(socket, channels) do
    case socket.assigns.active_channel do
      nil ->
        socket

      active_channel ->
        assign(
          socket,
          :active_channel,
          Enum.find(channels, &(&1.id == active_channel.id)) || active_channel
        )
    end
  end

  defp channel_path(channel), do: ~p"/?channel=#{channel.slug}"

  defp visible_text_channel?(channel) do
    channel.kind not in [:category, :thread_public, :thread_private, :thread_announcement]
  end
end
