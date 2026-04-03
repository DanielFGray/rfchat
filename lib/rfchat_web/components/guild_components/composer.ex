defmodule RfchatWeb.GuildComponents.Composer do
  @moduledoc false

  use RfchatWeb, :html

  import RfchatWeb.GuildComponents.Helpers

  attr :guild, :map, required: true

  def channel_composer(assigns) do
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

  def thread_composer(assigns) do
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
            <span class="font-semibold">{@guild.thread_reply_to_message.author.display_name}</span>
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

  def composer_button(assigns) do
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
end
