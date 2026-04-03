defmodule RfchatWeb.GuildComponents.Navigation do
  @moduledoc false

  use RfchatWeb, :html

  import RfchatWeb.GuildComponents.Helpers

  attr :section, :map, required: true
  attr :guild, :map, required: true

  def channel_nav_section(assigns) do
    ~H"""
    <section id={section_dom_id(@section.category)}>
      <div class="mb-1 flex items-center gap-2 px-2">
        <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
          {section_label(@section.category)}
        </p>
        <span class="rounded bg-base-300 px-1.5 py-0.5 text-[10px] font-semibold text-base-content/60">
          {length(@section.channels)}
        </span>
      </div>

      <div class="space-y-0.5">
        <.link
          :for={channel <- @section.channels}
          id={"channel-link-#{channel.slug}"}
          patch={channel_path(channel)}
          class={[
            "group flex items-center gap-2 rounded-md px-2 py-1.5 text-sm font-medium transition",
            channel_active?(@guild.active_channel, channel) &&
              "bg-base-100 text-base-content shadow-[inset_3px_0_0_color-mix(in_oklab,var(--color-primary)_32%,transparent)]",
            !channel_active?(@guild.active_channel, channel) &&
              "text-base-content/70 hover:bg-base-100 hover:text-base-content"
          ]}
        >
          <span class="text-base font-semibold text-base-content/50 transition group-hover:text-base-content/80">
            #
          </span>
          <span class="min-w-0 flex-1 truncate">{channel.name}</span>
          <span class="rounded bg-base-300 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em] text-base-content/60">
            {channel_kind_badge(channel.kind)}
          </span>
          <span
            :if={unread_count_for(channel, @guild.unread_counts) > 0}
            id={"channel-unread-#{channel.slug}"}
            class="rounded-full bg-violet-500/90 px-1.5 py-0.5 text-[10px] font-bold text-white"
          >
            {unread_count_for(channel, @guild.unread_counts)}
          </span>
          <span
            :if={unread_mentions_for(channel, @guild.unread_mentions) > 0}
            id={"channel-mention-#{channel.slug}"}
            class="flex size-5 items-center justify-center rounded-full bg-rose-500 text-[10px] font-black text-white shadow-[0_0_0_2px_var(--color-base-200)]"
            title="Unread mentions"
          >
            @
          </span>
        </.link>
      </div>
    </section>
    """
  end

  attr :entry, :map, required: true

  def member_presence_item(assigns) do
    ~H"""
    <div
      id={"member-presence-#{@entry.user.id}"}
      class="rounded-md px-2 py-2 transition hover:bg-base-100"
    >
      <div class="flex items-start gap-3">
        <div class="relative mt-0.5 shrink-0">
          <div class="flex size-8 items-center justify-center rounded-full bg-base-300 text-xs font-semibold text-base-content">
            {@entry.user.display_name |> String.first()}
          </div>
          <span class={[
            "absolute -bottom-0.5 -right-0.5 size-2.5 rounded-full border-2 border-base-200",
            member_status_class(@entry.status)
          ]} />
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <p class="truncate text-[13px] font-medium text-base-content">
              {@entry.user.display_name}
            </p>
            <span
              :if={@entry.user.membership.is_owner}
              class="rounded bg-emerald-500/15 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em] text-emerald-200"
            >
              owner
            </span>
          </div>

          <p class="mt-0.5 truncate text-[11px] text-base-content/50">@{@entry.user.username}</p>
          <p class="mt-1 text-[11px] text-base-content/65">
            {member_status_label(@entry.status)} · {Calendar.strftime(
              @entry.last_active_at,
              "%b %-d · %H:%M"
            )}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
