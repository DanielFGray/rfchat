defmodule RfchatWeb.GuildComponents.Threads do
  @moduledoc false

  use RfchatWeb, :html

  import RfchatWeb.GuildComponents.Helpers

  attr :guild, :map, required: true
  attr :message, :map, required: true
  attr :thread, :map, required: true

  def thread_panel(assigns) do
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
        class={["max-h-[28rem] overflow-y-auto px-4 py-3", scrollbar_classes()]}
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
          <RfchatWeb.GuildComponents.Composer.thread_composer guild={@guild} />
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

  def thread_message_item(assigns) do
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
            <span class="text-[11px] text-base-content/45">@{@thread_message.author.username}</span>
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
            class={["message-body mt-2 text-sm", message_body_classes()]}
            data-markdown-source={@thread_message.body}
          >
            {@thread_message.body}
          </div>

          <div class="mt-2 flex items-center gap-2 text-[11px] text-base-content/50">
            <span :if={edited_message?(@thread_message)}>(edited)</span>
            <span :if={deleted_message?(@thread_message)} class="text-amber-300">deleted</span>

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
end
