defmodule RfchatWeb.GuildComponents.Helpers do
  @moduledoc false

  use RfchatWeb, :html

  alias Rfchat.Chat

  def message_timestamp(datetime), do: Calendar.strftime(datetime, "%b %-d at %H:%M")

  def channel_path(channel), do: ~p"/?channel=#{channel.slug}"
  def thread_path(channel, thread), do: ~p"/?channel=#{channel.slug}&thread=#{thread.id}"

  def channel_active?(nil, _channel), do: false
  def channel_active?(active_channel, channel), do: active_channel.id == channel.id

  def unread_count_for(channel, unread_counts), do: Map.get(unread_counts, channel.id, 0)
  def unread_mentions_for(channel, unread_mentions), do: Map.get(unread_mentions, channel.id, 0)

  def thread_summary_for(message, thread_summaries), do: Map.get(thread_summaries, message.id)

  def thread_reply_count(message, thread_summaries) do
    case thread_summary_for(message, thread_summaries) do
      %{reply_count: count} -> count
      _ -> 0
    end
  end

  def thread_for_message(message, thread_summaries) do
    case thread_summary_for(message, thread_summaries) do
      %{thread: thread} -> thread
      _ -> nil
    end
  end

  def thread_open_for_message?(message, active_thread) do
    active_thread && active_thread.starter_message_id == message.id
  end

  def thread_title(thread), do: thread.name || "Thread"

  def section_dom_id(nil), do: "channel-section-uncategorized"
  def section_dom_id(category), do: "channel-section-#{category.slug}"

  def section_label(nil), do: "Text channels"
  def section_label(category), do: category.name

  def channel_kind_badge(:forum), do: "forum"
  def channel_kind_badge(:announcement), do: "news"
  def channel_kind_badge(:voice), do: "voice"
  def channel_kind_badge(:stage), do: "stage"
  def channel_kind_badge(_kind), do: "text"

  def member_status_class(:online), do: "bg-emerald-400"
  def member_status_class(:recent), do: "bg-amber-400"
  def member_status_class(:offline), do: "bg-base-content/35"

  def member_status_label(:online), do: "online"
  def member_status_label(:recent), do: "recent"
  def member_status_label(:offline), do: "offline"

  def mobile_sidebar_class(true), do: "translate-x-0"
  def mobile_sidebar_class(false), do: "-translate-x-full xl:translate-x-0"

  def mobile_members_class(true), do: "translate-x-0"
  def mobile_members_class(false), do: "translate-x-full xl:translate-x-0"

  def mobile_sidebar_overlay_class(true), do: "opacity-100 pointer-events-auto"
  def mobile_sidebar_overlay_class(false), do: "pointer-events-none opacity-0"

  def scrollbar_classes do
    [
      "[scrollbar-width:thin]",
      "[scrollbar-color:rgba(255,255,255,0.12)_transparent]",
      "[&::-webkit-scrollbar]:h-2.5",
      "[&::-webkit-scrollbar]:w-2.5",
      "[&::-webkit-scrollbar-track]:bg-transparent",
      "[&::-webkit-scrollbar-thumb]:rounded-full",
      "[&::-webkit-scrollbar-thumb]:border-2",
      "[&::-webkit-scrollbar-thumb]:border-transparent",
      "[&::-webkit-scrollbar-thumb]:bg-[rgba(255,255,255,0.12)]",
      "[&::-webkit-scrollbar-thumb]:bg-clip-padding",
      "[&::-webkit-scrollbar-thumb:hover]:bg-[rgba(255,255,255,0.2)]"
    ]
    |> Enum.join(" ")
  end

  def composer_shell_classes, do: "flex min-w-0 flex-1 flex-col gap-2"

  def composer_toolbar_region_classes do
    [
      "grid gap-[0.45rem] max-h-0 overflow-hidden opacity-0 pointer-events-none -translate-y-1",
      "transition-[max-height,opacity,transform] duration-200 ease-out",
      "data-[expanded=true]:max-h-24 data-[expanded=true]:translate-y-0",
      "data-[expanded=true]:opacity-100 data-[expanded=true]:pointer-events-auto"
    ]
    |> Enum.join(" ")
  end

  def composer_toolbar_button_classes do
    [
      "inline-flex min-h-[1.9rem] min-w-[1.9rem] items-center justify-center rounded-lg border",
      "border-base-300 bg-base-100 px-[0.2rem] text-[11px] font-bold text-base-content/70 transition",
      "hover:border-primary/40 hover:bg-primary/10 hover:text-primary",
      "data-[active=true]:border-primary/40 data-[active=true]:bg-primary/10",
      "data-[active=true]:text-primary"
    ]
    |> Enum.join(" ")
  end

  def message_body_classes do
    [
      "mt-0.5 break-words text-[15px] leading-6 text-base-content",
      "[&>p]:m-0 [&>ul]:m-0 [&>ul]:pl-5 [&>ol]:m-0 [&>ol]:pl-5",
      "[&_li+li]:mt-0.5 [&>p+p]:mt-[0.55rem] [&>p+ul]:mt-[0.55rem] [&>p+ol]:mt-[0.55rem]",
      "[&>ul+p]:mt-[0.55rem] [&>ol+p]:mt-[0.55rem] [&_.message-code-block]:mt-[0.55rem]",
      "[&_.message-link-embed]:mt-[0.55rem]"
    ]
    |> Enum.join(" ")
  end

  def reaction_summaries(message, current_user) do
    message.reactions
    |> Enum.group_by(fn reaction ->
      if reaction.emoji_id,
        do: {:custom, reaction.emoji_id},
        else: {:unicode, reaction.emoji_unicode}
    end)
    |> Enum.map(fn
      {{:custom, emoji_id}, reactions} ->
        reaction = List.first(reactions)

        %{
          kind: :custom,
          emoji_id: emoji_id,
          emoji_unicode: nil,
          label: reaction.emoji && reaction.emoji.name,
          url: reaction.emoji && reaction.emoji.asset && Chat.asset_url(reaction.emoji.asset),
          count: length(reactions),
          reacted?: Enum.any?(reactions, &(&1.user_id == current_user.id))
        }

      {{:unicode, emoji_unicode}, reactions} ->
        %{
          kind: :unicode,
          emoji_id: nil,
          emoji_unicode: emoji_unicode,
          label: emoji_unicode,
          url: nil,
          count: length(reactions),
          reacted?: Enum.any?(reactions, &(&1.user_id == current_user.id))
        }
    end)
    |> Enum.sort_by(fn summary ->
      case summary.kind do
        :unicode -> {0, summary.label}
        :custom -> {1, summary.label || ""}
      end
    end)
  end

  def reaction_dom_id(message, %{kind: :unicode, emoji_unicode: emoji_unicode}) do
    "reaction-#{message.id}-#{Base.url_encode64(emoji_unicode, padding: false)}"
  end

  def reaction_dom_id(message, %{kind: :custom, emoji_id: emoji_id}) do
    "reaction-#{message.id}-custom-#{emoji_id}"
  end

  def reaction_picker_open?(message, reaction_picker_message_id) do
    reaction_picker_message_id == message.id
  end

  def own_message?(message, current_user), do: message.author_id == current_user.id

  def deleted_message?(message) do
    not is_nil(message.deleted_at) or Map.get(message.metadata || %{}, "deleted", false)
  end

  def edited_message?(message),
    do: not is_nil(message.edited_at) and not deleted_message?(message)

  def message_controls_visible?(message_id, active_message_controls_id, message_action_menu_id) do
    active_message_controls_id == message_id or message_action_menu_id == message_id
  end

  def message_action_menu_open?(message_id, message_action_menu_id) do
    message_action_menu_id == message_id
  end

  def delete_confirmation_open?(message_id, delete_confirmation_message_id) do
    delete_confirmation_message_id == message_id
  end

  def can_open_message_controls?(message, current_user, can_send_messages?, can_manage_messages?) do
    not deleted_message?(message) and
      (can_send_messages? or own_message?(message, current_user) or can_manage_messages?)
  end
end
