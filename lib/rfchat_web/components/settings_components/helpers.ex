defmodule RfchatWeb.SettingsComponents.Helpers do
  @moduledoc false

  alias Rfchat.Chat

  def mention_alerts_enabled?(setting) do
    setting.desktop_enabled && setting.notify_on_mentions
  end

  def manageable_categories(sections) do
    sections
    |> Enum.map(& &1.category)
    |> Enum.reject(&is_nil/1)
  end

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
  def member_status_class(:offline), do: "bg-zinc-600"

  def member_status_label(:online), do: "online"
  def member_status_label(:recent), do: "recent"
  def member_status_label(:offline), do: "offline"

  def selected_member(entry, member_action_user_id), do: entry.user.id == member_action_user_id

  def member_action_available?(current_user, entry, permission_name) do
    current_user.id != entry.user.id and
      not entry.user.membership.is_owner and
      Chat.moderation_permission?(current_user, permission_name)
  end

  def moderation_case_label(:timeout), do: "Timeout"
  def moderation_case_label(:kick), do: "Kick"
  def moderation_case_label(:ban), do: "Ban"

  def moderation_case_label(other),
    do: other |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def member_timeout_label(entry) do
    timeout_until = entry.user.membership.timeout_until

    if timeout_until && DateTime.compare(timeout_until, DateTime.utc_now()) == :gt do
      Calendar.strftime(timeout_until, "%b %-d · %H:%M")
    end
  end

  def emoji_upload_error(:too_large), do: "That file is too large."
  def emoji_upload_error(:too_many_files), do: "Choose only one file."
  def emoji_upload_error(:not_accepted), do: "That file type is not allowed."
  def emoji_upload_error(_error), do: "Upload failed."

  def tab_active?(active_tab, tab), do: active_tab == tab

  def notification_level_value(nil), do: "default"

  def notification_level_value(membership),
    do: to_string(membership.notification_level || :default)

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
end
