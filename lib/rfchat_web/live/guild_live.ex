defmodule RfchatWeb.GuildLive do
  use RfchatWeb, :live_view

  import Phoenix.LiveView, only: [connected?: 1, push_navigate: 2, put_flash: 3, stream: 4]

  alias Rfchat.Chat
  alias Rfchat.Chat.UserNotificationSetting
  alias RfchatWeb.GuildLive.Events
  alias RfchatWeb.GuildLive.State
  alias RfchatWeb.Live.SharedHelpers

  @impl true
  def mount(params, _session, socket) do
    current_user = socket.assigns.current_user
    defer_hydration = Application.get_env(:rfchat, :defer_guild_live_hydration, true)

    custom_emojis =
      if connected?(socket) and not defer_hydration do
        SharedHelpers.emoji_entries_for_picker(current_user)
      else
        []
      end

    composer_mentions_json =
      if connected?(socket) and not defer_hydration do
        Jason.encode!(Chat.composer_mentions())
      else
        "[]"
      end

    composer_commands_json =
      if connected?(socket) and not defer_hydration do
        Jason.encode!(Chat.composer_slash_commands())
      else
        "[]"
      end

    channels =
      if connected?(socket) and not defer_hydration do
        Chat.list_channels_for_user(current_user)
      else
        []
      end

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
      |> assign(:channel_sections, [])
      |> assign(:custom_emojis, custom_emojis)
      |> assign(:custom_emojis_json, emoji_entries_json_for_picker(current_user, custom_emojis))
      |> assign(:member_presence, [])
      |> assign(:notification_setting, %UserNotificationSetting{user_id: current_user.id})
      |> assign(:composer_mentions_json, composer_mentions_json)
      |> assign(:composer_commands_json, composer_commands_json)
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

    requested_channel = initial_channel_from_params(params, current_user, defer_hydration)

    if requested_channel == :forbidden do
      fallback_channel =
        if connected?(socket) and not defer_hydration do
          Chat.default_channel_for_user(current_user)
        else
          Chat.default_channel_for_user(current_user)
        end

      if fallback_channel do
        {:ok,
         socket
         |> put_flash(:error, "You do not have access to that channel.")
         |> push_navigate(to: ~p"/?channel=#{fallback_channel.slug}")}
      else
        {:ok,
         socket
         |> put_flash(:error, "You do not currently have access to any channels in this server.")}
      end
    else
      initial_channel = requested_channel || List.first(channels)

      case {Chat.list_channels(), initial_channel, connected?(socket) and not defer_hydration} do
        {[], _none_visible, _sync_ready?} ->
          {:ok,
           socket
           |> put_flash(
             :error,
             "This guild has not been bootstrapped yet. Run `mix run priv/repo/seeds.exs`."
           )}

        {_all_channels, nil, true} ->
          {:ok,
           socket
           |> put_flash(
             :error,
             "You do not currently have access to any channels in this server."
           )}

        {_all_channels, nil, false} ->
          {:ok, State.queue_initial_hydration(socket)}

        {_all_channels, active_channel, _sync_ready?} ->
          socket =
            socket
            |> assign(:active_channel, active_channel)
            |> State.set_channel_loading(active_channel)
            |> State.queue_initial_hydration()

          {:ok, socket}
      end
    end
  end

  @impl true
  def handle_params(params, uri, socket), do: Events.handle_params(params, uri, socket)

  @impl true
  def handle_info(message, socket), do: Events.handle_info(message, socket)

  @impl true
  def handle_event(event, params, socket), do: Events.handle_event(event, params, socket)

  defp emoji_entries_json_for_picker(_current_user, entries) do
    Jason.encode!(%{
      custom: entries,
      branding: SharedHelpers.server_branding()
    })
  end

  defp initial_channel_from_params(%{"channel" => _slug}, _current_user, true), do: nil

  defp initial_channel_from_params(%{"channel" => slug}, current_user, false) do
    case Chat.get_channel_by_slug_for_user(slug, current_user) do
      {:ok, channel} -> channel
      {:error, :forbidden} -> :forbidden
      _ -> nil
    end
  end

  defp initial_channel_from_params(_params, _current_user, _defer_hydration), do: nil
end
