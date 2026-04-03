defmodule RfchatWeb.SettingsComponents.Tabs do
  @moduledoc false

  use RfchatWeb, :html

  import RfchatWeb.SettingsComponents.Helpers

  def profile_tab(assigns) do
    ~H"""
    <div id="settings-view-profile">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Profile basics
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Account profile</h2>

      <.form for={@profile_form} id="profile-form" phx-submit="save_profile" class="mt-5 space-y-4">
        <.input field={@profile_form[:display_name]} type="text" label="Display name" />
        <.input field={@profile_form[:username]} type="text" label="Username" />
        <.input field={@profile_form[:email]} type="email" label="Email" />

        <div class="rounded-xl border border-dashed border-base-300 bg-base-200 p-4">
          <p class="text-[11px] font-semibold uppercase tracking-[0.16em] text-base-content/50">
            Avatar
          </p>
          <p class="mt-2 text-sm text-base-content/70">
            Avatar upload will be added in next iteration. This route now owns profile settings.
          </p>
        </div>

        <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
          Save profile
        </.button>
      </.form>
    </div>
    """
  end

  def notifications_tab(assigns) do
    ~H"""
    <div id="settings-view-notifications">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Notifications
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Global preferences</h2>

      <div class="mt-5 rounded-xl border border-base-300 bg-base-200 p-4">
        <div class="flex items-center justify-between gap-3">
          <div>
            <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/50">
              Mention alerts
            </p>
            <p class="mt-1 text-[11px] text-base-content/70">
              Notify when someone mentions you in another channel.
            </p>
          </div>

          <button
            :if={not mention_alerts_enabled?(@notification_setting)}
            type="button"
            phx-click="enable_desktop_mentions"
            id="enable-desktop-mentions"
            class="rounded-md bg-violet-500 px-2.5 py-1 text-[11px] font-semibold text-white transition hover:bg-violet-400"
          >
            Enable
          </button>

          <button
            :if={mention_alerts_enabled?(@notification_setting)}
            type="button"
            phx-click="disable_desktop_mentions"
            id="disable-desktop-mentions"
            class="rounded-md px-2.5 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
          >
            On
          </button>
        </div>
      </div>

      <.form
        for={@notification_form}
        id="notification-form"
        phx-submit="save_notifications"
        class="mt-5 grid gap-4 md:grid-cols-2"
      >
        <.input field={@notification_form[:desktop_enabled]} type="checkbox" label="Desktop alerts" />
        <.input field={@notification_form[:email_enabled]} type="checkbox" label="Email alerts" />
        <.input field={@notification_form[:push_enabled]} type="checkbox" label="Push alerts" />
        <.input
          field={@notification_form[:notify_on_all_messages]}
          type="checkbox"
          label="Notify on all messages"
        />
        <.input
          field={@notification_form[:notify_on_mentions]}
          type="checkbox"
          label="Notify on mentions"
        />
        <.input
          field={@notification_form[:suppress_everyone]}
          type="checkbox"
          label="Suppress @everyone"
        />
        <.input
          field={@notification_form[:suppress_roles]}
          type="checkbox"
          label="Suppress role mentions"
        />

        <div class="md:col-span-2">
          <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
            Save notification preferences
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  def channel_notifications_tab(assigns) do
    ~H"""
    <div id="settings-view-channel-notifications">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Channel notifications
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Per-channel overrides</h2>

      <div class={["mt-5 space-y-3 overflow-y-auto max-h-[70vh] pr-1", scrollbar_classes()]}>
        <div
          :for={section <- @channel_sections}
          id={"channel-notification-section-#{section.category && section.category.slug || "uncategorized"}"}
          class="rounded-xl border border-base-300 bg-base-200 p-3"
        >
          <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            {section_label(section.category)}
          </p>

          <div class="mt-3 space-y-2">
            <div
              :for={channel <- section.channels}
              id={"channel-notification-#{channel.slug}"}
              class="rounded-lg border border-base-300 bg-base-100 p-3"
            >
              <div class="mb-2 flex items-center justify-between gap-2">
                <p class="text-sm font-semibold text-base-content">#{channel.name}</p>
                <span class="rounded bg-base-300 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em] text-base-content/50">
                  {channel_kind_badge(channel.kind)}
                </span>
              </div>

              <.form
                for={to_form(%{}, as: :channel_notification)}
                id={"channel-notification-form-#{channel.slug}"}
                phx-submit="save_channel_notification"
                class="grid gap-3 md:grid-cols-3"
              >
                <input type="hidden" name="channel_notification[channel_id]" value={channel.id} />

                <.input
                  field={to_form(%{}, as: :channel_notification)[:notification_level]}
                  name="channel_notification[notification_level]"
                  type="select"
                  label="Level"
                  options={[
                    {"Default", "default"},
                    {"All messages", "all_messages"},
                    {"Mentions", "mentions"},
                    {"Nothing", "nothing"}
                  ]}
                  value={notification_level_value(@channel_memberships[channel.id])}
                />

                <.input
                  field={to_form(%{}, as: :channel_notification)[:is_favorite]}
                  name="channel_notification[is_favorite]"
                  type="checkbox"
                  label="Favorite"
                  checked={
                    @channel_memberships[channel.id] && @channel_memberships[channel.id].is_favorite
                  }
                />

                <div class="flex items-end">
                  <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
                    Save
                  </.button>
                </div>
              </.form>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def theme_tab(assigns) do
    ~H"""
    <div id="settings-view-theme">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Theme
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Appearance preferences</h2>

      <div class="mt-5 rounded-xl border border-base-300 bg-base-200 p-4">
        <p class="text-sm text-base-content/80">Choose your app theme:</p>
        <div class="mt-3">
          <Layouts.theme_toggle />
        </div>
      </div>
    </div>
    """
  end
end
