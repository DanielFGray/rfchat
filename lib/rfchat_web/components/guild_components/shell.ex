defmodule RfchatWeb.GuildComponents.Shell do
  @moduledoc false

  use RfchatWeb, :html

  import RfchatWeb.GuildComponents.Helpers

  attr :guild, :map, required: true

  def mobile_overlays(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="close_mobile_sidebar"
      id="mobile-sidebar-overlay"
      class={[
        "fixed inset-0 z-30 bg-black/65 transition xl:hidden",
        mobile_sidebar_overlay_class(@guild.mobile_sidebar_open?)
      ]}
      aria-label="Close channel list"
    />

    <button
      type="button"
      phx-click="close_mobile_members"
      id="mobile-members-overlay"
      class={[
        "fixed inset-0 z-30 bg-black/65 transition xl:hidden",
        mobile_sidebar_overlay_class(@guild.mobile_members_open?)
      ]}
      aria-label="Close members list"
    />
    """
  end

  attr :guild, :map, required: true

  def mobile_channel_drawer(assigns) do
    ~H"""
    <aside
      id="mobile-channel-drawer"
      class={[
        "fixed inset-y-0 left-0 z-40 flex w-[85vw] max-w-72 shrink-0 flex-col border-r border-base-300 bg-base-200 transition-transform duration-200 ease-out xl:static xl:z-auto xl:w-64 xl:max-w-none xl:border-b-0 xl:border-r-base-300",
        mobile_sidebar_class(@guild.mobile_sidebar_open?)
      ]}
    >
      <div class="flex items-center justify-between border-b border-base-300 px-4 py-3 shadow-sm">
        <Layouts.server_identity server={@guild.server_settings} />

        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="close_mobile_sidebar"
            id="close-mobile-sidebar"
            class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-100 hover:text-base-content xl:hidden"
          >
            Close
          </button>
          <Layouts.theme_toggle />
        </div>
      </div>

      <div class={["flex-1 overflow-y-auto px-2 py-3", scrollbar_classes()]}>
        <div class="mb-2 flex items-center justify-between px-2">
          <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            Channels
          </p>
          <div class="flex items-center gap-2">
            <span class="rounded bg-base-300 px-1.5 py-0.5 text-[10px] font-semibold text-base-content/60">
              {length(@guild.channels)}
            </span>

            <.link
              navigate={~p"/settings"}
              id="open-settings-link"
              class="rounded-md px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-base-content/70 transition hover:bg-base-100 hover:text-base-content"
            >
              Settings
            </.link>
          </div>
        </div>

        <nav class="space-y-3" aria-label="Guild channels">
          <RfchatWeb.GuildComponents.Navigation.channel_nav_section
            :for={section <- @guild.channel_sections}
            section={section}
            guild={@guild}
          />
        </nav>
      </div>

      <div class="border-t border-base-300 bg-base-100 px-3 py-2">
        <div class="flex items-center justify-between gap-3 rounded-md px-1 py-1">
          <div class="flex min-w-0 items-center gap-2">
            <div class="relative">
              <div class="flex size-9 items-center justify-center rounded-full bg-base-300 text-xs font-semibold text-base-content">
                {@guild.current_user.display_name |> String.first()}
              </div>
              <span class="absolute -bottom-0.5 -right-0.5 size-3 rounded-full border-2 border-base-100 bg-emerald-400" />
            </div>
            <div class="min-w-0">
              <p class="truncate text-[13px] font-semibold leading-4 text-base-content">
                {@guild.current_user.display_name}
              </p>
              <p class="truncate text-[11px] text-base-content/65">@{@guild.current_user.username}</p>
            </div>
          </div>

          <.link
            href={~p"/logout"}
            method="delete"
            id="logout-link"
            class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
          >
            Log out
          </.link>
        </div>

        <.link
          navigate={~p"/settings"}
          id="open-settings-link-footer"
          class="mt-2 block rounded-md border border-base-300 bg-base-200 px-2 py-2 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
        >
          Open settings panel
        </.link>
      </div>
    </aside>
    """
  end

  attr :guild, :map, required: true

  def members_drawer(assigns) do
    ~H"""
    <aside
      id="mobile-members-drawer"
      class={[
        "fixed inset-y-0 right-0 z-40 flex h-dvh w-[82vw] max-w-72 shrink-0 flex-col border-l border-base-300 bg-base-200 transition-transform duration-200 ease-out xl:static xl:z-auto xl:h-auto xl:w-60 xl:max-w-none",
        mobile_members_class(@guild.mobile_members_open?)
      ]}
    >
      <div class="border-b border-base-300 px-4 py-3">
        <div class="flex items-center justify-between gap-3">
          <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            Members
          </p>
          <button
            type="button"
            phx-click="close_mobile_members"
            id="close-mobile-members"
            class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-100 hover:text-base-content xl:hidden"
          >
            Close
          </button>
        </div>
        <div class="mt-2 flex items-center justify-between text-xs text-base-content/65">
          <span>{length(@guild.member_presence)} visible</span>
          <span class="rounded bg-base-300 px-1.5 py-0.5 text-[10px] font-semibold text-base-content/80">
            {Enum.count(@guild.member_presence, &(&1.status == :online))} online
          </span>
        </div>
      </div>

      <div
        id="member-sidebar"
        class={["flex-1 space-y-0.5 overflow-y-auto px-2 py-3", scrollbar_classes()]}
      >
        <RfchatWeb.GuildComponents.Navigation.member_presence_item
          :for={entry <- @guild.member_presence}
          entry={entry}
        />
      </div>
    </aside>
    """
  end
end
