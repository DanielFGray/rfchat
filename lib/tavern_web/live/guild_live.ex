defmodule TavernWeb.GuildLive do
  use TavernWeb, :live_view

  import Phoenix.LiveView, only: [connected?: 1, stream: 4]

  alias Tavern.Chat
  alias Tavern.Chat.Topics
  alias Tavern.Chat.UserNotificationSetting
  alias TavernWeb.GuildLive.Events
  alias TavernWeb.GuildLive.State
  alias TavernWeb.Live.SharedHelpers

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    if connected?(socket) do
      Topics.subscribe_guild()
    end

    server_settings = Chat.get_server_settings()

    socket =
      socket
      |> assign(:server_settings, server_settings)
      |> assign(:guild_name, server_settings.name)
      |> assign(:current_server, server_settings)
      |> assign(:page_title, server_settings.name)
      |> assign(:current_user, current_user)
      |> assign(:channels, [])
      |> assign(:subscribed_channel_ids, MapSet.new())
      |> assign(:channel_sections, [])
      |> assign(:custom_emojis, [])
      |> assign(:custom_emojis_json, emoji_entries_json_for_picker([]))
      |> assign(:member_presence, [])
      |> assign(:notification_setting, %UserNotificationSetting{user_id: current_user.id})
      |> assign(:composer_mentions_json, "[]")
      |> assign(:composer_commands_json, "[]")
      |> assign(:unread_counts, %{})
      |> assign(:unread_mentions, %{})
      |> assign(:navigation_ready?, false)
      |> assign(:members_ready?, false)
      |> assign(:channel_ready?, false)
      |> assign(:channel_request_token, nil)
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
      |> assign(:can_archive_thread?, false)
      |> assign(:can_lock_thread?, false)
      |> assign(:reply_to_message, nil)
      |> assign(:thread_reply_to_message, nil)
      |> assign(:editing_message_id, nil)
      |> assign(:editing_form, nil)
      |> assign(:message_count, 0)
      |> assign(:messages_empty?, true)
      |> assign(:thread_summaries, %{})
      |> assign(:typing_users, [])
      |> assign(:thread_typing_users, [])
      |> assign(:active_thread, nil)
      |> assign(:thread_focus?, false)
      |> assign(:thread_message_count, 0)
      |> assign(:thread_messages_empty?, true)
      |> State.assign_message_form()
      |> State.assign_thread_message_form()
      |> stream(:messages, [], reset: true)
      |> stream(:thread_messages, [], reset: true)

    {:ok, State.queue_initial_hydration(socket)}
  end

  @impl true
  def handle_params(params, uri, socket), do: Events.handle_params(params, uri, socket)

  @impl true
  def handle_info(message, socket), do: Events.handle_info(message, socket)

  @impl true
  def handle_event(event, params, socket), do: Events.handle_event(event, params, socket)

  defp emoji_entries_json_for_picker(entries) do
    Jason.encode!(%{
      custom: entries,
      branding: SharedHelpers.server_branding()
    })
  end
end
