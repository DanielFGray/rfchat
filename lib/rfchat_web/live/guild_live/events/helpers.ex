defmodule RfchatWeb.GuildLive.Events.Helpers do
  @moduledoc false

  def normalize_message_id(message_id), do: message_id

  def own_message?(message, current_user), do: message.author_id == current_user.id

  def deleted_message?(message) do
    not is_nil(message.deleted_at) or Map.get(message.metadata || %{}, "deleted", false)
  end

  def can_open_message_controls?(message, current_user, can_send_messages?, can_manage_messages?) do
    not deleted_message?(message) and
      (can_send_messages? or own_message?(message, current_user) or can_manage_messages?)
  end
end
