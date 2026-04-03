defmodule RfchatWeb.GuildLive do
  use RfchatWeb, :live_view

  alias Rfchat.Accounts
  alias Rfchat.Chat
  alias RfchatWeb.GuildLive.Events
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
  def handle_params(params, uri, socket), do: Events.handle_params(params, uri, socket)

  @impl true
  def handle_info(message, socket), do: Events.handle_info(message, socket)

  @impl true
  def handle_event(event, params, socket), do: Events.handle_event(event, params, socket)

  defp emoji_entries_json_for_picker(current_user) do
    Jason.encode!(%{
      custom: SharedHelpers.emoji_entries_for_picker(current_user),
      branding: SharedHelpers.server_branding()
    })
  end
end
