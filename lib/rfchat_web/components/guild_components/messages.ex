defmodule RfchatWeb.GuildComponents.Messages do
  @moduledoc false

  use RfchatWeb, :html

  alias Rfchat.Chat

  import RfchatWeb.GuildComponents.Helpers

  attr :guild, :map, required: true

  def active_channel_view(assigns) do
    ~H"""
    <.channel_header guild={@guild} />
    <.message_stream guild={@guild} />
    <RfchatWeb.GuildComponents.Composer.channel_composer guild={@guild} />
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

  def channel_header(assigns) do
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

  def message_stream(assigns) do
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

  def message_item(assigns) do
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

          <RfchatWeb.GuildComponents.Threads.thread_panel
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

  def reaction_picker(assigns) do
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
  attr :thread, :map, default: nil

  def message_actions(assigns) do
    ~H"""
    <div class={[
      "absolute right-4 top-0 z-10 flex items-center gap-1 rounded-full border border-base-300 bg-base-100/95 p-1 shadow-lg transition",
      message_controls_visible?(
        @message.id,
        @guild.active_message_controls_id,
        @guild.message_action_menu_id
      ) &&
        "opacity-100 translate-y-0 pointer-events-auto",
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
end
