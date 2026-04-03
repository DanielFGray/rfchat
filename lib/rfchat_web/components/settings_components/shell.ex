defmodule RfchatWeb.SettingsComponents.Shell do
  @moduledoc false

  use RfchatWeb, :html

  import RfchatWeb.SettingsComponents.Helpers

  def page(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-300 text-base-content transition-colors duration-200">
      <div class="mx-auto flex w-full max-w-7xl flex-col gap-4 px-4 py-4 sm:gap-5 sm:py-5 lg:flex-row lg:gap-6 lg:px-6 lg:py-6">
        <.sidebar {assigns} />

        <section class="min-w-0 flex-1 rounded-2xl border border-base-300 bg-base-100 p-4 shadow-lg sm:p-5 lg:p-6">
          <%= if @active_tab == "profile" do %>
            <RfchatWeb.SettingsComponents.Tabs.profile_tab {assigns} />
          <% end %>

          <%= if @active_tab == "notifications" do %>
            <RfchatWeb.SettingsComponents.Tabs.notifications_tab {assigns} />
          <% end %>

          <%= if @active_tab == "channel_notifications" do %>
            <RfchatWeb.SettingsComponents.Tabs.channel_notifications_tab {assigns} />
          <% end %>

          <%= if @active_tab == "theme" do %>
            <RfchatWeb.SettingsComponents.Tabs.theme_tab {assigns} />
          <% end %>

          <%= if @active_tab == "server" do %>
            <RfchatWeb.SettingsComponents.Server.server_tab {assigns} />
          <% end %>
        </section>
      </div>

      <RfchatWeb.SettingsComponents.Managers.channel_manager {assigns} />
      <RfchatWeb.SettingsComponents.Managers.emoji_manager {assigns} />
    </div>
    """
  end

  def sidebar(assigns) do
    ~H"""
    <aside class="w-full shrink-0 rounded-2xl border border-base-300 bg-base-100 p-3 shadow-lg lg:sticky lg:top-6 lg:w-64">
      <div class="mb-3 border-b border-base-300 px-2 pb-3">
        <p class="text-[10px] font-bold uppercase tracking-[0.22em] text-base-content/50 sm:text-[11px]">
          Settings
        </p>
        <h1
          id="settings-panel-title"
          class="mt-1 text-base font-semibold text-base-content sm:text-lg"
        >
          Consolidated panel
        </h1>
      </div>

      <nav
        class={[
          "-mx-1 flex gap-2 overflow-x-auto px-1 pb-1",
          scrollbar_classes(),
          "lg:mx-0 lg:block lg:space-y-1 lg:overflow-visible lg:px-0 lg:pb-0"
        ]}
        aria-label="Settings tabs"
      >
        <.tab_button active_tab={@active_tab} tab="profile" id="settings-tab-profile" label="Profile" />
        <.tab_button
          active_tab={@active_tab}
          tab="notifications"
          id="settings-tab-notifications"
          label="Notifications"
        />
        <.tab_button
          active_tab={@active_tab}
          tab="channel_notifications"
          id="settings-tab-channel-notifications"
          label="Channel notifications"
        />
        <.tab_button active_tab={@active_tab} tab="theme" id="settings-tab-theme" label="Theme" />
        <.tab_button
          active_tab={@active_tab}
          tab="server"
          id="settings-tab-server"
          label="Server management"
        />
      </nav>

      <.link
        navigate={~p"/"}
        id="back-to-chat-link"
        class="mt-4 inline-flex min-h-11 items-center justify-center rounded-xl border border-base-300 px-3.5 py-2.5 text-sm font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content lg:flex"
      >
        Back to chat
      </.link>
    </aside>
    """
  end

  attr :active_tab, :string, required: true
  attr :tab, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true

  def tab_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        "min-h-11 shrink-0 rounded-xl px-3.5 py-2.5 text-left text-sm font-medium whitespace-nowrap transition lg:w-full",
        tab_active?(@active_tab, @tab) && "bg-primary/15 text-primary",
        !tab_active?(@active_tab, @tab) &&
          "text-base-content/75 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      {@label}
    </button>
    """
  end
end
