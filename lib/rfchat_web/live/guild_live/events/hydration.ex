defmodule RfchatWeb.GuildLive.Events.Hydration do
  @moduledoc false

  alias RfchatWeb.GuildLive.State
  alias RfchatWeb.Live.SharedHelpers

  def handle_info(:hydrate_navigation, socket) do
    current_user = socket.assigns.current_user
    custom_emojis = SharedHelpers.emoji_entries_for_picker(current_user)

    socket =
      socket
      |> State.hydrate_navigation()
      |> Phoenix.Component.assign(
        :notification_setting,
        Rfchat.Chat.get_user_notification_setting(current_user)
      )
      |> Phoenix.Component.assign(:custom_emojis, custom_emojis)
      |> Phoenix.Component.assign(
        :custom_emojis_json,
        Jason.encode!(%{
          custom: custom_emojis,
          branding: SharedHelpers.server_branding()
        })
      )
      |> Phoenix.Component.assign(
        :composer_mentions_json,
        Jason.encode!(Rfchat.Chat.composer_mentions())
      )
      |> Phoenix.Component.assign(
        :composer_commands_json,
        Jason.encode!(Rfchat.Chat.composer_slash_commands())
      )

    send(self(), :hydrate_unread_state)

    {:noreply, socket}
  end

  def handle_info(:hydrate_unread_state, socket) do
    socket =
      try do
        State.hydrate_unread_state(socket)
      rescue
        DBConnection.ConnectionError -> socket
      end

    {:noreply, socket}
  end

  def handle_info(:hydrate_members, socket) do
    {:noreply, State.hydrate_members(socket)}
  end

  def handle_info({:hydrate_channel, channel_id, channel_request_token}, socket) do
    if State.hydrate_channel_stale?(socket, channel_id, channel_request_token) do
      {:noreply, socket}
    else
      {:noreply, State.load_channel(socket, socket.assigns.active_channel)}
    end
  end
end
