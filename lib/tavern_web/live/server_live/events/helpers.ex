defmodule TavernWeb.ServerLive.Events.Helpers do
  @moduledoc false

  def normalize_message_id(message_id), do: message_id

  def slowmode_message(seconds_left),
    do: "Slowmode is on. You can send again in #{seconds_left}s."

  def own_message?(message, current_user), do: message.author_id == current_user.id

  defdelegate deleted_message?(message), to: Tavern.Chat.Message, as: :deleted?

  def can_open_message_controls?(message, current_user, can_send_messages?, can_manage_messages?) do
    not deleted_message?(message) and
      (can_send_messages? or own_message?(message, current_user) or can_manage_messages?)
  end
end
