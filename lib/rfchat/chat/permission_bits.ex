defmodule Rfchat.Chat.PermissionBits do
  @moduledoc false

  import Bitwise

  @flags %{
    view_channel: 1 <<< 0,
    send_messages: 1 <<< 1,
    create_public_threads: 1 <<< 2,
    create_private_threads: 1 <<< 3,
    send_messages_in_threads: 1 <<< 4,
    embed_links: 1 <<< 5,
    attach_files: 1 <<< 6,
    add_reactions: 1 <<< 7,
    use_external_emojis: 1 <<< 8,
    use_external_stickers: 1 <<< 9,
    mention_everyone: 1 <<< 10,
    manage_messages: 1 <<< 11,
    manage_channels: 1 <<< 12,
    manage_roles: 1 <<< 13,
    manage_emojis_and_stickers: 1 <<< 14,
    manage_webhooks: 1 <<< 15,
    manage_events: 1 <<< 16,
    kick_members: 1 <<< 17,
    ban_members: 1 <<< 18,
    moderate_members: 1 <<< 19,
    administrator: 1 <<< 20,
    manage_bots: 1 <<< 21
  }

  def flags, do: @flags
  def flag(name), do: Map.fetch!(@flags, name)

  def combine(names) when is_list(names) do
    Enum.reduce(names, 0, fn name, acc -> acc + flag(name) end)
  end
end
