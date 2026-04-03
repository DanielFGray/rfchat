defmodule RfchatWeb.GuildComponents do
  use RfchatWeb, :html

  alias Rfchat.Chat

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
          <.channel_nav_section
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

  def active_channel_view(assigns) do
    ~H"""
    <.channel_header guild={@guild} />
    <.message_stream guild={@guild} />
    <.channel_composer guild={@guild} />
    """
  end

  def empty_channel_view(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 items-center justify-center px-5 py-10">
      <div class="max-w-lg rounded-lg border border-dashed border-base-300 bg-base-100 p-8 text-center">
        <p class="text-xs font-semibold uppercase tracking-[0.28em] text-base-content/50">
          No accessible channels
        </p>
        <h2 class="mt-3 text-2xl font-semibold text-base-content">
          This account has nowhere to land yet.
        </h2>
        <p class="mt-3 text-sm leading-7 text-base-content/70">
          Ask a server owner to grant channel access or seed a default role with view permissions.
        </p>
      </div>
    </div>
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
        <.member_presence_item :for={entry <- @guild.member_presence} entry={entry} />
      </div>
    </aside>
    """
  end

  attr :section, :map, required: true
  attr :guild, :map, required: true

  defp channel_nav_section(assigns) do
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

  attr :guild, :map, required: true

  defp channel_header(assigns) do
    ~H"""
    <header class="flex items-center justify-between border-b border-base-300 bg-base-200/95 px-4 py-3 shadow-sm backdrop-blur">
      <div class="flex min-w-0 items-center gap-3">
        <button
          type="button"
          phx-click="toggle_mobile_sidebar"
          id="open-mobile-sidebar"
          class="inline-flex shrink-0 items-center justify-center rounded-md px-2 py-1 text-sm font-semibold text-base-content/70 transition hover:bg-base-100 hover:text-base-content xl:hidden"
        >
          ☰
        </button>
        <div class="flex items-center gap-2">
          <span class="text-lg font-bold text-base-content/50">#</span>
          <div class="min-w-0">
            <h1 class="truncate text-[15px] font-semibold text-base-content">
              {@guild.active_channel.name}
            </h1>
            <p class="mt-0.5 truncate text-xs text-base-content/65">
              {@guild.active_channel.topic || "No topic set for this channel yet."}
            </p>
          </div>
        </div>
      </div>

      <div class="ml-4 flex items-center gap-2 text-xs text-base-content/65">
        <button
          type="button"
          phx-click="toggle_mobile_members"
          id="open-mobile-members"
          class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-100 hover:text-base-content xl:hidden"
        >
          <span aria-hidden="true">👥</span>
          <span>{length(@guild.member_presence)}</span>
        </button>
        <span class="hidden rounded-md bg-base-100 px-2 py-1 font-medium sm:inline-flex">
          {@guild.message_count} messages
        </span>
        <span class="hidden items-center gap-1 rounded-md bg-emerald-500/10 px-2 py-1 text-emerald-300 sm:inline-flex">
          <span class="size-2 rounded-full bg-emerald-400" /> online
        </span>
      </div>
    </header>
    """
  end

  attr :guild, :map, required: true

  defp message_stream(assigns) do
    ~H"""
    <div
      id="message-scroll-region"
      class={["flex-1 overflow-y-auto", scrollbar_classes()]}
      phx-hook="MessageListHook"
    >
      <div
        :if={@guild.messages_empty?}
        class="mx-4 my-6 rounded-lg border border-dashed border-base-300 bg-base-100 p-6 text-left"
      >
        <p class="text-[11px] font-bold uppercase tracking-[0.22em] text-base-content/50">
          Start of #{@guild.active_channel.slug}
        </p>
        <p class="mt-2 text-sm leading-6 text-base-content/80">
          This is the beginning of the
          <span class="font-semibold text-base-content">##{@guild.active_channel.name}</span>
          channel. Drop a message to get the conversation moving.
        </p>
      </div>

      <div id="message-list" phx-update="stream" class="px-0 py-3">
        <.message_item
          :for={{dom_id, message} <- @guild.streams.messages}
          dom_id={dom_id}
          message={message}
          guild={@guild}
        />
      </div>
    </div>
    """
  end

  attr :dom_id, :any, required: true
  attr :message, :map, required: true
  attr :guild, :map, required: true

  defp message_item(assigns) do
    assigns =
      assign(
        assigns,
        :thread,
        thread_for_message(assigns.message, assigns.guild.thread_summaries)
      )

    ~H"""
    <div id={@dom_id} class="group relative px-4 py-0.5 hover:bg-base-100/80">
      <article class="relative flex gap-3 py-2">
        <div class="shrink-0 pt-0.5">
          <div class="flex size-10 items-center justify-center rounded-full bg-base-300 text-[13px] font-semibold text-base-content">
            {@message.author.display_name |> String.first()}
          </div>
        </div>

        <div class="min-w-0 flex-1" phx-click="toggle_message_controls" phx-value-id={@message.id}>
          <div :if={@message.reply_to} class="mt-1 text-xs text-base-content/65">
            <span class="truncate">
              Replying to
              <span class="font-semibold text-base-content/80">
                {@message.reply_to.author.display_name}
              </span>
              · {@message.reply_to.body}
            </span>
          </div>

          <div class="flex items-baseline gap-2">
            <p class="truncate text-[15px] font-medium leading-5 text-base-content">
              {@message.author.display_name}
            </p>
            <time class="shrink-0 text-[11px] text-base-content/50">
              {message_timestamp(@message.inserted_at)}
            </time>
          </div>

          <%= if @guild.editing_message_id == @message.id do %>
            <.form
              for={@guild.editing_form}
              id={"edit-message-form-#{@message.id}"}
              phx-submit="save_edit"
              class="mt-2"
            >
              <input type="hidden" name="message[id]" value={@message.id} />
              <div class="rounded-md border border-primary/30 bg-base-100 p-2">
                <.input
                  field={@guild.editing_form[:body]}
                  type="textarea"
                  id={"edit-message-body-#{@message.id}"}
                  rows="3"
                  class="min-h-24 w-full resize-none rounded-md border border-base-300 bg-base-200 px-3 py-2 text-sm text-base-content outline-none transition focus:border-primary"
                />
                <div class="mt-2 flex items-center justify-end gap-2">
                  <button
                    type="button"
                    phx-click="cancel_edit"
                    class="rounded-md px-2.5 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="rounded-md bg-violet-500 px-2.5 py-1 text-[11px] font-semibold text-white transition hover:bg-violet-400"
                  >
                    Save
                  </button>
                </div>
              </div>
            </.form>
          <% else %>
            <div class={["message-body", message_body_classes()]} data-markdown-source={@message.body}>
              {@message.body}
            </div>
          <% end %>

          <div class="mt-1 flex items-center gap-2 text-[11px] text-base-content/50">
            <span :if={edited_message?(@message)}>(edited)</span>
            <span :if={deleted_message?(@message)} class="text-amber-300">deleted</span>
          </div>

          <div class="mt-2 flex flex-wrap items-center gap-1.5">
            <button
              :for={reaction <- reaction_summaries(@message, @guild.current_user)}
              type="button"
              phx-click={
                if(reaction.kind == :unicode, do: "toggle_reaction", else: "toggle_custom_reaction")
              }
              phx-value-id={@message.id}
              phx-value-emoji={reaction.emoji_unicode}
              phx-value-emoji_id={reaction.emoji_id}
              id={reaction_dom_id(@message, reaction)}
              disabled={!@guild.can_add_reactions? or deleted_message?(@message)}
              class={[
                "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-semibold transition",
                reaction.reacted? && "border-violet-400/60 bg-violet-500/20 text-violet-100",
                !reaction.reacted? &&
                  "border-base-300 bg-base-100 text-base-content/70 hover:border-base-content/20 hover:text-base-content",
                (!@guild.can_add_reactions? or deleted_message?(@message)) &&
                  "cursor-not-allowed opacity-50 hover:border-base-300 hover:text-base-content/70"
              ]}
            >
              <span :if={reaction.kind == :unicode}>{reaction.emoji_unicode}</span>
              <img
                :if={reaction.kind == :custom}
                src={reaction.url}
                alt={reaction.label}
                class="size-4 rounded object-cover"
              />
              <span>{reaction.count}</span>
            </button>
          </div>

          <.reaction_picker
            :if={reaction_picker_open?(@message, @guild.reaction_picker_message_id)}
            message={@message}
            guild={@guild}
          />

          <div :if={@thread} class="mt-3 flex flex-wrap items-center gap-2">
            <span
              id={"thread-summary-#{@message.id}"}
              class={[
                "inline-flex items-center gap-2 rounded-full border px-3 py-1 text-[11px] font-semibold transition",
                thread_open_for_message?(@message, @guild.active_thread) &&
                  "border-primary/40 bg-primary/10 text-primary",
                !thread_open_for_message?(@message, @guild.active_thread) &&
                  "border-base-300 bg-base-100 text-base-content/75"
              ]}
            >
              <.icon name="hero-chat-bubble-left-right" class="size-3.5" />
              <span>{thread_reply_count(@message, @guild.thread_summaries)} replies</span>
              <span class="truncate text-base-content/45">{thread_title(@thread)}</span>
            </span>

            <.link
              patch={thread_path(@guild.active_channel, @thread)}
              id={"focus-thread-#{@message.id}"}
              class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-3 py-1 text-[11px] font-semibold text-base-content/70 transition hover:border-base-content/20 hover:bg-base-200 hover:text-base-content"
            >
              Full thread
            </.link>
          </div>

          <.thread_panel
            :if={@thread && thread_open_for_message?(@message, @guild.active_thread)}
            guild={@guild}
            message={@message}
            thread={@thread}
          />

          <p :if={!@guild.can_add_reactions?} class="mt-2 text-[11px] text-base-content/50">
            Reactions are disabled for your permissions in this channel.
          </p>
        </div>

        <.message_actions guild={@guild} message={@message} thread={@thread} />
      </article>
    </div>
    """
  end

  attr :guild, :map, required: true
  attr :message, :map, required: true

  defp reaction_picker(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="close_reaction_picker"
      id={"reaction-picker-overlay-#{@message.id}"}
      class="fixed inset-0 z-10 bg-black/50 md:hidden"
      aria-label="Close reaction picker"
    />

    <div
      id={"reaction-picker-#{@message.id}"}
      phx-hook="ReactionPickerHook"
      data-custom-emojis={@guild.custom_emojis_json}
      class="fixed inset-x-0 bottom-0 z-20 rounded-t-[1.4rem] border border-base-300 bg-base-100 p-3 shadow-2xl md:absolute md:right-4 md:top-14 md:left-auto md:bottom-auto md:w-[22rem] md:rounded-2xl"
    >
      <div class="mb-2 flex items-center justify-between gap-3">
        <div>
          <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            Reactions
          </p>
          <p class="mt-1 text-xs text-base-content/65">
            Pick a default or custom emoji.
          </p>
        </div>
        <button
          type="button"
          phx-click="close_reaction_picker"
          id={"close-reaction-picker-#{@message.id}"}
          class="rounded-md px-2 py-1 text-[10px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          Close
        </button>
      </div>

      <div class="space-y-3">
        <div>
          <label
            for={"reaction-picker-search-#{@message.id}"}
            class="mb-2 block text-[10px] font-bold uppercase tracking-[0.16em] text-base-content/50"
          >
            Search
          </label>
          <input
            id={"reaction-picker-search-#{@message.id}"}
            type="search"
            placeholder="Search emojis"
            data-reaction-picker-search
            class="w-full rounded-xl border border-base-300 bg-base-200 px-3 py-2 text-sm text-base-content outline-none transition placeholder:text-base-content/45 focus:border-primary/60"
          />
        </div>

        <div>
          <p class="mb-2 text-[10px] font-bold uppercase tracking-[0.16em] text-base-content/50">
            Default
          </p>

          <div class="grid min-h-0 grid-cols-[2.75rem_minmax(0,1fr)] gap-3">
            <div
              data-reaction-picker-categories
              class={[
                "flex max-h-[40vh] flex-col gap-2 overflow-y-auto pr-1 md:max-h-72",
                scrollbar_classes()
              ]}
            />

            <div
              data-reaction-picker-defaults
              data-message-id={@message.id}
              class={[
                "grid max-h-[40vh] grid-cols-8 gap-1 overflow-y-auto pr-1 md:max-h-72 md:grid-cols-8",
                scrollbar_classes()
              ]}
            >
              <button
                :for={emoji <- Chat.default_reaction_emojis()}
                type="button"
                phx-click="toggle_reaction"
                phx-value-id={@message.id}
                phx-value-emoji={emoji}
                id={"reaction-picker-default-#{@message.id}-#{Base.url_encode64(emoji, padding: false)}"}
                class="flex aspect-square size-10 items-center justify-center rounded-xl text-xl transition hover:bg-base-200 md:size-9 md:text-lg"
              >
                <span>{emoji}</span>
              </button>
            </div>
          </div>
        </div>

        <div>
          <p class="mb-2 text-[10px] font-bold uppercase tracking-[0.16em] text-base-content/50">
            Custom
          </p>
          <div
            :if={@guild.custom_emojis != []}
            class="grid grid-cols-6 gap-1.5 md:grid-cols-6"
            data-reaction-picker-custom
          >
            <button
              :for={emoji <- @guild.custom_emojis}
              type="button"
              phx-click="toggle_custom_reaction"
              phx-value-id={@message.id}
              phx-value-emoji_id={emoji.id}
              id={"reaction-picker-custom-#{@message.id}-#{emoji.id}"}
              data-custom-emoji-id={emoji.id}
              data-custom-emoji-name={emoji.name}
              data-custom-emoji-shortcode={emoji.shortcode}
              class="group flex aspect-square size-11 items-center justify-center rounded-xl text-[10px] font-medium text-base-content/80 transition hover:bg-base-200 hover:text-base-content md:size-10"
            >
              <img
                src={emoji.url}
                alt={emoji.name}
                class="size-7 rounded-md object-cover transition group-hover:scale-105"
              />
              <span class="sr-only">{emoji.name}</span>
            </button>
          </div>
          <p
            :if={@guild.custom_emojis == []}
            class="rounded-xl border border-dashed border-base-300 bg-base-200 px-3 py-3 text-xs text-base-content/50"
          >
            No custom emoji uploaded yet.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :guild, :map, required: true
  attr :message, :map, required: true
  attr :thread, :map, required: true

  defp thread_panel(assigns) do
    ~H"""
    <div
      id={"thread-panel-#{@message.id}"}
      class={[
        "mt-4 overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm",
        @guild.thread_focus? && "ring-1 ring-primary/25"
      ]}
    >
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-200/80 px-4 py-3">
        <div class="min-w-0">
          <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-base-content/45">
            Thread
          </p>
          <div class="mt-1 flex items-center gap-2">
            <h3 class="truncate text-sm font-semibold text-base-content">
              {thread_title(@thread)}
            </h3>
            <span class="rounded-full bg-base-300 px-2 py-0.5 text-[10px] font-bold uppercase tracking-[0.14em] text-base-content/60">
              {@guild.thread_message_count} replies
            </span>
          </div>
          <p class="mt-1 truncate text-xs text-base-content/55">
            Started by {@message.author.display_name}
          </p>
        </div>

        <div class="flex items-center gap-2">
          <.link
            patch={thread_path(@guild.active_channel, @thread)}
            id={"thread-view-focus-#{@message.id}"}
            class="rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-base-content/75 transition hover:bg-base-100 hover:text-base-content"
          >
            {if @guild.thread_focus?, do: "Focused", else: "Focus"}
          </.link>
          <.link
            :if={@guild.thread_focus?}
            patch={channel_path(@guild.active_channel)}
            id={"thread-back-to-channel-#{@message.id}"}
            class="rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-base-content/75 transition hover:bg-base-100 hover:text-base-content"
          >
            Back to channel
          </.link>
          <button
            type="button"
            phx-click="close_thread"
            id={"close-thread-#{@message.id}"}
            class="rounded-md px-2.5 py-1.5 text-[11px] font-semibold text-base-content/75 transition hover:bg-base-100 hover:text-base-content"
          >
            Close
          </button>
        </div>
      </div>

      <div
        id={"thread-scroll-region-#{@message.id}"}
        data-enable-notifications="false"
        class={[
          "max-h-[28rem] overflow-y-auto px-4 py-3",
          scrollbar_classes()
        ]}
        phx-hook="MessageListHook"
      >
        <div
          :if={@guild.thread_messages_empty?}
          class="rounded-xl border border-dashed border-base-300 bg-base-200/60 px-4 py-5 text-sm text-base-content/65"
        >
          No thread replies yet. Kick this conversation off.
        </div>

        <div id={"thread-message-list-#{@message.id}"} phx-update="stream" class="space-y-3">
          <.thread_message_item
            :for={{thread_dom_id, thread_message} <- @guild.streams.thread_messages}
            dom_id={thread_dom_id}
            thread_message={thread_message}
            guild={@guild}
          />
        </div>
      </div>

      <div class="border-t border-base-300 bg-base-100 px-4 py-4">
        <%= if @guild.can_send_thread_messages? do %>
          <.thread_composer guild={@guild} />
        <% else %>
          <div class="rounded-xl border border-warning/30 bg-warning/15 px-4 py-3 text-sm text-warning-content">
            You can view this thread, but you do not have permission to reply in it.
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :dom_id, :any, required: true
  attr :thread_message, :map, required: true
  attr :guild, :map, required: true

  defp thread_message_item(assigns) do
    ~H"""
    <div id={@dom_id} class="rounded-xl border border-base-300 bg-base-200/60 px-3 py-3">
      <div class="flex gap-3">
        <div class="flex size-8 shrink-0 items-center justify-center rounded-full bg-base-300 text-[11px] font-semibold text-base-content">
          {@thread_message.author.display_name |> String.first()}
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <p class="text-[13px] font-semibold text-base-content">
              {@thread_message.author.display_name}
            </p>
            <span class="text-[11px] text-base-content/45">
              @{@thread_message.author.username}
            </span>
            <time class="text-[11px] text-base-content/45">
              {message_timestamp(@thread_message.inserted_at)}
            </time>
          </div>

          <div
            :if={@thread_message.reply_to}
            class="mt-1 flex items-center gap-2 border-l-2 border-base-300 pl-3 text-xs text-base-content/60"
          >
            <span class="truncate">
              Replying to
              <span class="font-semibold text-base-content/80">
                {@thread_message.reply_to.author.display_name}
              </span>
              · {@thread_message.reply_to.body}
            </span>
          </div>

          <div
            class={[
              "message-body mt-2 text-sm",
              message_body_classes()
            ]}
            data-markdown-source={@thread_message.body}
          >
            {@thread_message.body}
          </div>

          <div class="mt-2 flex items-center gap-2 text-[11px] text-base-content/50">
            <span :if={edited_message?(@thread_message)}>(edited)</span>
            <span :if={deleted_message?(@thread_message)} class="text-amber-300">
              deleted
            </span>

            <button
              type="button"
              phx-click="reply_in_thread"
              phx-value-id={@thread_message.id}
              id={"reply-in-thread-#{@thread_message.id}"}
              disabled={!@guild.can_send_thread_messages? or deleted_message?(@thread_message)}
              class="rounded-md px-1.5 py-0.5 font-semibold text-base-content/65 transition hover:bg-base-100 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-50"
            >
              Reply
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :guild, :map, required: true
  attr :message, :map, required: true
  attr :thread, :map, default: nil

  defp message_actions(assigns) do
    ~H"""
    <div class={[
      "absolute right-4 top-0 z-10 flex items-center gap-1 rounded-full border border-base-300 bg-base-100/95 p-1 shadow-lg transition",
      message_controls_visible?(
        @message.id,
        @guild.active_message_controls_id,
        @guild.message_action_menu_id
      ) && "opacity-100 translate-y-0 pointer-events-auto",
      !message_controls_visible?(
        @message.id,
        @guild.active_message_controls_id,
        @guild.message_action_menu_id
      ) &&
        "pointer-events-none -translate-y-1 opacity-0 group-hover:pointer-events-auto group-hover:translate-y-0 group-hover:opacity-100 group-focus-within:pointer-events-auto group-focus-within:translate-y-0 group-focus-within:opacity-100"
    ]}>
      <button
        :if={
          can_open_message_controls?(
            @message,
            @guild.current_user,
            @guild.can_send_messages?,
            @guild.can_manage_messages?
          )
        }
        type="button"
        phx-click="reply_message"
        phx-value-id={@message.id}
        id={"quick-reply-message-#{@message.id}"}
        disabled={!@guild.can_send_messages? or deleted_message?(@message)}
        class="inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-50"
        aria-label="Reply"
        title="Reply"
      >
        <.icon name="hero-arrow-uturn-left" class="size-4" />
      </button>

      <button
        :if={@thread}
        type="button"
        phx-click="open_thread"
        phx-value-id={@thread.id}
        id={"open-thread-#{@message.id}"}
        class="inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content"
        aria-label="Open thread"
        title="Open thread"
      >
        <.icon name="hero-chat-bubble-left-right" class="size-4" />
      </button>

      <button
        :if={is_nil(@thread) and @guild.can_create_public_threads? and not deleted_message?(@message)}
        type="button"
        phx-click="create_thread"
        phx-value-id={@message.id}
        id={"create-thread-#{@message.id}"}
        class="inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content"
        aria-label="Start thread"
        title="Start thread"
      >
        <.icon name="hero-chat-bubble-bottom-center-text" class="size-4" />
      </button>

      <button
        type="button"
        phx-click="toggle_reaction_picker"
        phx-value-id={@message.id}
        id={"open-reaction-picker-#{@message.id}"}
        disabled={!@guild.can_add_reactions? or deleted_message?(@message)}
        class="inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-50"
        aria-label="Add reaction"
        title="Add reaction"
      >
        <.icon name="hero-face-smile" class="size-4" />
      </button>

      <button
        :if={own_message?(@message, @guild.current_user) or @guild.can_manage_messages?}
        type="button"
        phx-click="toggle_message_action_menu"
        phx-value-id={@message.id}
        id={"open-message-actions-#{@message.id}"}
        class="inline-flex size-8 items-center justify-center rounded-full text-base-content/75 transition hover:bg-base-200 hover:text-base-content"
        aria-label="More actions"
        title="More actions"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </button>

      <div
        :if={message_action_menu_open?(@message.id, @guild.message_action_menu_id)}
        id={"message-actions-menu-#{@message.id}"}
        class="absolute right-0 top-full mt-2 min-w-40 rounded-xl border border-base-300 bg-base-100 p-1.5 shadow-xl"
      >
        <%= if @thread do %>
          <button
            type="button"
            phx-click="open_thread"
            phx-value-id={@thread.id}
            id={"open-thread-menu-#{@message.id}"}
            class="flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
          >
            <span>Open thread</span>
            <span class="text-base-content/50">#</span>
          </button>
        <% else %>
          <button
            :if={@guild.can_create_public_threads? and not deleted_message?(@message)}
            type="button"
            phx-click="create_thread"
            phx-value-id={@message.id}
            id={"create-thread-menu-#{@message.id}"}
            class="flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
          >
            <span>Start thread</span>
            <span class="text-base-content/50">#</span>
          </button>
        <% end %>

        <button
          :if={own_message?(@message, @guild.current_user) and not deleted_message?(@message)}
          type="button"
          phx-click="edit_message"
          phx-value-id={@message.id}
          id={"edit-message-#{@message.id}"}
          class="flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
        >
          <span>Edit</span>
          <span class="text-base-content/50">✎</span>
        </button>

        <%= if (own_message?(@message, @guild.current_user) or @guild.can_manage_messages?) and not deleted_message?(@message) do %>
          <%= if delete_confirmation_open?(@message.id, @guild.delete_confirmation_message_id) do %>
            <div
              id={"confirm-delete-message-#{@message.id}"}
              class="mt-1 rounded-lg border border-rose-500/20 bg-rose-500/8 p-3"
            >
              <p class="text-[11px] font-semibold text-rose-100">
                Delete this message?
              </p>
              <div class="mt-2 flex items-center gap-2">
                <button
                  type="button"
                  phx-click="delete_message"
                  phx-value-id={@message.id}
                  id={"delete-message-#{@message.id}"}
                  class="rounded-md bg-rose-500 px-2.5 py-1 text-[11px] font-semibold text-white transition hover:bg-rose-400"
                >
                  Delete
                </button>
                <button
                  type="button"
                  phx-click="cancel_delete_message"
                  id={"cancel-delete-message-#{@message.id}"}
                  class="rounded-md px-2.5 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
                >
                  Cancel
                </button>
              </div>
            </div>
          <% else %>
            <button
              type="button"
              phx-click="confirm_delete_message"
              phx-value-id={@message.id}
              id={"prompt-delete-message-#{@message.id}"}
              class="flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-[11px] font-semibold text-rose-200 transition hover:bg-rose-500/10 hover:text-rose-100"
            >
              <span>Delete</span>
              <span class="text-rose-300">🗑</span>
            </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :guild, :map, required: true

  defp channel_composer(assigns) do
    ~H"""
    <div class="border-t border-base-300 bg-base-200 px-4 pt-4 pb-[calc(1rem+env(safe-area-inset-bottom))]">
      <%= if @guild.can_send_messages? do %>
        <.form
          for={@guild.message_form}
          id="message-form"
          phx-submit="send_message"
          phx-hook="RichComposerHook"
          data-composer-target="channel"
          data-placeholder="Message channel"
          data-mentions={@guild.composer_mentions_json}
          data-commands={@guild.composer_commands_json}
        >
          <div class="rounded-lg border border-base-300 bg-base-100 shadow-sm">
            <div
              :if={@guild.reply_to_message}
              id="replying-to-banner"
              class="flex items-center justify-between border-b border-base-300 bg-primary/10 px-3 py-2 text-xs text-primary"
            >
              <div class="min-w-0">
                Replying to
                <span class="font-semibold">{@guild.reply_to_message.author.display_name}</span>
                <p class="truncate text-[11px] text-primary/70">
                  {@guild.reply_to_message.body}
                </p>
              </div>
              <button
                type="button"
                phx-click="cancel_reply"
                class="rounded px-1.5 py-0.5 text-[11px] font-semibold text-primary transition hover:bg-base-200"
              >
                Cancel
              </button>
            </div>

            <div class="flex items-end gap-2 px-3 py-3">
              <div
                id="rich-composer-shell"
                data-rich-composer-shell
                phx-update="ignore"
                class={composer_shell_classes()}
              >
                <div class={composer_toolbar_region_classes()} data-expanded="false">
                  <div
                    id="rich-composer-toolbar"
                    data-rich-composer-toolbar
                    class="flex flex-wrap items-center gap-1.5"
                  >
                    <.composer_button action="bold" label="Bold">B</.composer_button>
                    <.composer_button action="italic" label="Italic">
                      <span class="text-[13px] italic font-semibold leading-none">I</span>
                    </.composer_button>
                    <.composer_button action="inline-code" label="Inline code">
                      <span class="text-[11px] font-black leading-none">&lt;/&gt;</span>
                    </.composer_button>
                    <.composer_button action="code-block" label="Code block">
                      <span class="text-[11px] font-black leading-none">```</span>
                    </.composer_button>
                    <.composer_button action="mention" label="Insert mention">
                      <span class="text-[13px] font-black leading-none">@</span>
                    </.composer_button>
                    <.composer_button action="slash" label="Insert slash command">
                      <span class="text-[13px] font-black leading-none">/</span>
                    </.composer_button>
                  </div>

                  <p :if={!@guild.can_mention_everyone?} class="m-0 text-[11px] text-amber-200">
                    @everyone and locked roles need extra permission
                  </p>
                </div>

                <div data-rich-composer-editor class="min-h-0" />

                <textarea
                  data-rich-composer-body
                  name={@guild.message_form[:body].name}
                  class="hidden"
                >{@guild.message_form[:body].value || ""}</textarea>
                <textarea
                  data-rich-composer-metadata
                  name={@guild.message_form[:metadata].name}
                  class="hidden"
                ></textarea>
              </div>

              <div class="flex h-full shrink-0 flex-col items-center justify-end gap-2 pb-0.5">
                <button
                  type="button"
                  aria-label="Upload attachments"
                  title="Upload attachments"
                  disabled
                  class="inline-flex size-8 cursor-not-allowed items-center justify-center rounded-md border border-base-300 bg-base-200 text-base-content/50 opacity-70 pointer-events-none"
                >
                  <.icon name="hero-paper-clip" class="size-4" />
                </button>

                <.button
                  aria-label="Send message"
                  title="Send message"
                  id="send-message-button"
                  class="inline-flex size-8 items-center justify-center rounded-md bg-violet-500 p-0 text-white transition hover:bg-violet-400"
                >
                  <.icon name="hero-paper-airplane" class="size-4" />
                </.button>
              </div>
            </div>
          </div>
        </.form>
      <% else %>
        <div class="rounded-lg border border-warning/30 bg-warning/15 px-4 py-3 text-sm text-warning-content">
          You can view this channel, but you do not have permission to send messages here.
        </div>
      <% end %>
    </div>
    """
  end

  attr :guild, :map, required: true

  defp thread_composer(assigns) do
    ~H"""
    <.form
      for={@guild.thread_message_form}
      id="thread-message-form"
      phx-submit="send_thread_message"
      phx-hook="RichComposerHook"
      data-composer-target="thread"
      data-placeholder="Reply in thread"
      data-mentions={@guild.composer_mentions_json}
      data-commands={@guild.composer_commands_json}
    >
      <div class="rounded-xl border border-base-300 bg-base-200/70 shadow-sm">
        <div
          :if={@guild.thread_reply_to_message}
          id="thread-replying-to-banner"
          class="flex items-center justify-between border-b border-base-300 bg-primary/10 px-3 py-2 text-xs text-primary"
        >
          <div class="min-w-0">
            Replying to
            <span class="font-semibold">
              {@guild.thread_reply_to_message.author.display_name}
            </span>
            <p class="truncate text-[11px] text-primary/70">
              {@guild.thread_reply_to_message.body}
            </p>
          </div>
          <button
            type="button"
            phx-click="cancel_thread_reply"
            class="rounded px-1.5 py-0.5 text-[11px] font-semibold text-primary transition hover:bg-base-100"
          >
            Cancel
          </button>
        </div>

        <div class="flex items-end gap-2 px-3 py-3">
          <div
            id="thread-rich-composer-shell"
            data-rich-composer-shell
            phx-update="ignore"
            class={composer_shell_classes()}
          >
            <div class={composer_toolbar_region_classes()} data-expanded="false">
              <div data-rich-composer-toolbar class="flex flex-wrap items-center gap-1.5">
                <.composer_button action="bold" label="Bold">B</.composer_button>
                <.composer_button action="italic" label="Italic">
                  <span class="text-[13px] italic font-semibold leading-none">I</span>
                </.composer_button>
                <.composer_button action="inline-code" label="Inline code">
                  <span class="text-[11px] font-black leading-none">&lt;/&gt;</span>
                </.composer_button>
                <.composer_button action="code-block" label="Code block">
                  <span class="text-[11px] font-black leading-none">```</span>
                </.composer_button>
                <.composer_button action="mention" label="Insert mention">
                  <span class="text-[13px] font-black leading-none">@</span>
                </.composer_button>
              </div>
            </div>

            <div data-rich-composer-editor class="min-h-0" />

            <textarea
              data-rich-composer-body
              name={@guild.thread_message_form[:body].name}
              class="hidden"
            >{@guild.thread_message_form[:body].value || ""}</textarea>
            <textarea
              data-rich-composer-metadata
              name={@guild.thread_message_form[:metadata].name}
              class="hidden"
            ></textarea>
          </div>

          <.button
            aria-label="Send thread message"
            title="Send thread message"
            id="send-thread-message-button"
            class="inline-flex size-8 items-center justify-center rounded-md bg-violet-500 p-0 text-white transition hover:bg-violet-400"
          >
            <.icon name="hero-paper-airplane" class="size-4" />
          </.button>
        </div>
      </div>
    </.form>
    """
  end

  attr :action, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp composer_button(assigns) do
    ~H"""
    <button
      type="button"
      data-editor-action={@action}
      class={composer_toolbar_button_classes()}
      data-active="false"
      aria-label={@label}
      title={@label}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :entry, :map, required: true

  defp member_presence_item(assigns) do
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

          <p class="mt-0.5 truncate text-[11px] text-base-content/50">
            @{@entry.user.username}
          </p>
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

  defp message_timestamp(datetime), do: Calendar.strftime(datetime, "%b %-d at %H:%M")

  defp channel_path(channel), do: ~p"/?channel=#{channel.slug}"
  defp thread_path(channel, thread), do: ~p"/?channel=#{channel.slug}&thread=#{thread.id}"

  defp channel_active?(nil, _channel), do: false
  defp channel_active?(active_channel, channel), do: active_channel.id == channel.id

  defp unread_count_for(channel, unread_counts), do: Map.get(unread_counts, channel.id, 0)
  defp unread_mentions_for(channel, unread_mentions), do: Map.get(unread_mentions, channel.id, 0)

  defp thread_summary_for(message, thread_summaries), do: Map.get(thread_summaries, message.id)

  defp thread_reply_count(message, thread_summaries) do
    case thread_summary_for(message, thread_summaries) do
      %{reply_count: count} -> count
      _ -> 0
    end
  end

  defp thread_for_message(message, thread_summaries) do
    case thread_summary_for(message, thread_summaries) do
      %{thread: thread} -> thread
      _ -> nil
    end
  end

  defp thread_open_for_message?(message, active_thread) do
    active_thread && active_thread.starter_message_id == message.id
  end

  defp thread_title(thread), do: thread.name || "Thread"

  defp section_dom_id(nil), do: "channel-section-uncategorized"
  defp section_dom_id(category), do: "channel-section-#{category.slug}"

  defp section_label(nil), do: "Text channels"
  defp section_label(category), do: category.name

  defp channel_kind_badge(:forum), do: "forum"
  defp channel_kind_badge(:announcement), do: "news"
  defp channel_kind_badge(:voice), do: "voice"
  defp channel_kind_badge(:stage), do: "stage"
  defp channel_kind_badge(_kind), do: "text"

  defp member_status_class(:online), do: "bg-emerald-400"
  defp member_status_class(:recent), do: "bg-amber-400"
  defp member_status_class(:offline), do: "bg-base-content/35"

  defp member_status_label(:online), do: "online"
  defp member_status_label(:recent), do: "recent"
  defp member_status_label(:offline), do: "offline"

  defp mobile_sidebar_class(true), do: "translate-x-0"
  defp mobile_sidebar_class(false), do: "-translate-x-full xl:translate-x-0"

  defp mobile_members_class(true), do: "translate-x-0"
  defp mobile_members_class(false), do: "translate-x-full xl:translate-x-0"

  defp mobile_sidebar_overlay_class(true), do: "opacity-100 pointer-events-auto"
  defp mobile_sidebar_overlay_class(false), do: "pointer-events-none opacity-0"

  defp scrollbar_classes do
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

  defp composer_shell_classes, do: "flex min-w-0 flex-1 flex-col gap-2"

  defp composer_toolbar_region_classes do
    [
      "grid gap-[0.45rem] max-h-0 overflow-hidden opacity-0 pointer-events-none -translate-y-1",
      "transition-[max-height,opacity,transform] duration-200 ease-out",
      "data-[expanded=true]:max-h-24 data-[expanded=true]:translate-y-0",
      "data-[expanded=true]:opacity-100 data-[expanded=true]:pointer-events-auto"
    ]
    |> Enum.join(" ")
  end

  defp composer_toolbar_button_classes do
    [
      "inline-flex min-h-[1.9rem] min-w-[1.9rem] items-center justify-center rounded-lg border",
      "border-base-300 bg-base-100 px-[0.2rem] text-[11px] font-bold text-base-content/70 transition",
      "hover:border-primary/40 hover:bg-primary/10 hover:text-primary",
      "data-[active=true]:border-primary/40 data-[active=true]:bg-primary/10",
      "data-[active=true]:text-primary"
    ]
    |> Enum.join(" ")
  end

  defp message_body_classes do
    [
      "mt-0.5 break-words text-[15px] leading-6 text-base-content",
      "[&>p]:m-0 [&>ul]:m-0 [&>ul]:pl-5 [&>ol]:m-0 [&>ol]:pl-5",
      "[&_li+li]:mt-0.5 [&>p+p]:mt-[0.55rem] [&>p+ul]:mt-[0.55rem] [&>p+ol]:mt-[0.55rem]",
      "[&>ul+p]:mt-[0.55rem] [&>ol+p]:mt-[0.55rem] [&_.message-code-block]:mt-[0.55rem]",
      "[&_.message-link-embed]:mt-[0.55rem]"
    ]
    |> Enum.join(" ")
  end

  defp reaction_summaries(message, current_user) do
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

  defp reaction_dom_id(message, %{kind: :unicode, emoji_unicode: emoji_unicode}) do
    "reaction-#{message.id}-#{Base.url_encode64(emoji_unicode, padding: false)}"
  end

  defp reaction_dom_id(message, %{kind: :custom, emoji_id: emoji_id}) do
    "reaction-#{message.id}-custom-#{emoji_id}"
  end

  defp reaction_picker_open?(message, reaction_picker_message_id) do
    reaction_picker_message_id == message.id
  end

  defp own_message?(message, current_user), do: message.author_id == current_user.id

  defp deleted_message?(message) do
    not is_nil(message.deleted_at) or Map.get(message.metadata || %{}, "deleted", false)
  end

  defp edited_message?(message),
    do: not is_nil(message.edited_at) and not deleted_message?(message)

  defp message_controls_visible?(message_id, active_message_controls_id, message_action_menu_id) do
    active_message_controls_id == message_id or message_action_menu_id == message_id
  end

  defp message_action_menu_open?(message_id, message_action_menu_id) do
    message_action_menu_id == message_id
  end

  defp delete_confirmation_open?(message_id, delete_confirmation_message_id) do
    delete_confirmation_message_id == message_id
  end

  defp can_open_message_controls?(message, current_user, can_send_messages?, can_manage_messages?) do
    not deleted_message?(message) and
      (can_send_messages? or own_message?(message, current_user) or can_manage_messages?)
  end
end
