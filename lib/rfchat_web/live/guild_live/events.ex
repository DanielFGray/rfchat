defmodule RfchatWeb.GuildLive.Events do
  @moduledoc false

  alias RfchatWeb.GuildLive.Events.Messages
  alias RfchatWeb.GuildLive.Events.Mobile
  alias RfchatWeb.GuildLive.Events.Navigation
  alias RfchatWeb.GuildLive.Events.Notifications
  alias RfchatWeb.GuildLive.Events.Reactions
  alias RfchatWeb.GuildLive.Events.Threads

  def handle_params(params, uri, socket), do: Navigation.handle_params(params, uri, socket)

  def handle_info({type, _payload} = message, socket)
      when type in [:message_created, :message_updated, :message_deleted] do
    Messages.handle_info(message, socket)
  end

  def handle_info(message, socket)
      when message in [:channels_reordered] or
             (is_tuple(message) and tuple_size(message) == 2 and
                elem(message, 0) in [:channel_created, :channel_updated, :channel_deleted]) do
    Navigation.handle_info(message, socket)
  end

  def handle_event(event, params, socket)

  def handle_event(event, params, socket)
      when event in [
             "toggle_mobile_sidebar",
             "close_mobile_sidebar",
             "toggle_mobile_members",
             "close_mobile_members"
           ] do
    Mobile.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in ["enable_desktop_mentions", "disable_desktop_mentions"] do
    Notifications.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "toggle_message_controls",
             "toggle_message_action_menu",
             "close_message_action_menu",
             "confirm_delete_message",
             "cancel_delete_message",
             "send_message",
             "reply_message",
             "cancel_reply",
             "edit_message",
             "cancel_edit",
             "save_edit",
             "delete_message"
           ] do
    Messages.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "create_thread",
             "open_thread",
             "open_thread_focus",
             "close_thread",
             "reply_in_thread",
             "cancel_thread_reply",
             "send_thread_message"
           ] do
    Threads.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "toggle_reaction",
             "toggle_custom_reaction",
             "toggle_reaction_picker",
             "close_reaction_picker"
           ] do
    Reactions.handle_event(event, params, socket)
  end
end
