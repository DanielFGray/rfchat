defmodule RfchatWeb.SettingsComponents.Managers do
  @moduledoc false

  use RfchatWeb, :html

  import RfchatWeb.SettingsComponents.Helpers

  def channel_manager(assigns) do
    ~H"""
    <div
      :if={@can_manage_channels?}
      id="channel-manager-overlay"
      class={[
        "fixed inset-0 z-40 bg-black/70 transition",
        @manage_channels_open? && "opacity-100 pointer-events-auto",
        !@manage_channels_open? && "pointer-events-none opacity-0"
      ]}
      phx-click="close_manage_channels"
    />

    <aside
      :if={@can_manage_channels?}
      id="channel-manager-panel"
      aria-hidden={if(@manage_channels_open?, do: "false", else: "true")}
      class={[
        "fixed inset-y-0 right-0 z-50 flex w-full max-w-xl flex-col border-l border-base-300 bg-base-100 shadow-2xl transition-transform duration-200 ease-out lg:shadow-2xl",
        !@manage_channels_open? && "shadow-none lg:shadow-[-16px_0_48px_rgba(0,0,0,0.45)]",
        @manage_channels_open? && "pointer-events-auto",
        !@manage_channels_open? && "pointer-events-none",
        @manage_channels_open? && "translate-x-0",
        !@manage_channels_open? && "translate-x-full"
      ]}
    >
      <div class="flex items-center justify-between border-b border-base-300 px-5 py-4">
        <div>
          <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-base-content/50">
            Server structure
          </p>
          <h2 class="mt-1 text-lg font-semibold text-base-content">Channels and categories</h2>
        </div>

        <button
          type="button"
          phx-click="close_manage_channels"
          id="close-channel-manager"
          class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          Close
        </button>
      </div>

      <div class="grid min-h-0 flex-1 gap-0 lg:grid-cols-[1.15fr_0.95fr]">
        <div class={[
          "min-h-0 overflow-y-auto border-b border-base-300 px-4 py-4 lg:border-b-0 lg:border-r",
          scrollbar_classes()
        ]}>
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              phx-click="new_channel_form"
              phx-value-mode="create_text"
              id="new-text-channel"
              class="rounded-md bg-violet-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-violet-400"
            >
              New channel
            </button>
            <button
              type="button"
              phx-click="new_channel_form"
              phx-value-mode="create_category"
              id="new-category"
              class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
            >
              New category
            </button>
          </div>

          <div class="mt-4 space-y-3">
            <div
              :for={section <- @all_channel_sections}
              id={"manager-#{section_dom_id(section.category)}"}
              class="rounded-xl border border-base-300 bg-base-200 p-3"
            >
              <div class="flex items-center justify-between gap-3">
                <div>
                  <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
                    {section_label(section.category)}
                  </p>
                  <p class="mt-1 text-xs text-base-content/70">
                    {if section.category,
                      do: section.category.topic || "Category container",
                      else: "Channels without a category"}
                  </p>
                </div>

                <button
                  :if={section.category}
                  type="button"
                  phx-click="edit_channel"
                  phx-value-id={section.category.id}
                  id={"edit-category-#{section.category.slug}"}
                  class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
                >
                  Edit
                </button>
              </div>

              <div class="mt-3 space-y-2">
                <div
                  :for={channel <- section.channels}
                  id={"manage-channel-#{channel.slug}"}
                  class="rounded-lg border border-base-300 bg-base-100 px-3 py-2"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div class="flex items-center gap-2">
                        <span class="text-base-content/50">#</span>
                        <p class="truncate text-sm font-semibold text-base-content">{channel.name}</p>
                        <span class="rounded bg-base-300 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em] text-base-content/50">
                          {channel_kind_badge(channel.kind)}
                        </span>
                      </div>
                      <p class="mt-1 truncate text-xs text-base-content/70">
                        {channel.topic || "No topic set."}
                      </p>
                    </div>

                    <div class="flex items-center gap-1">
                      <button
                        type="button"
                        phx-click="move_channel"
                        phx-value-id={channel.id}
                        phx-value-direction="up"
                        id={"move-channel-up-#{channel.slug}"}
                        class="rounded px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
                      >
                        ↑
                      </button>
                      <button
                        type="button"
                        phx-click="move_channel"
                        phx-value-id={channel.id}
                        phx-value-direction="down"
                        id={"move-channel-down-#{channel.slug}"}
                        class="rounded px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
                      >
                        ↓
                      </button>
                      <button
                        type="button"
                        phx-click="edit_channel"
                        phx-value-id={channel.id}
                        id={"edit-channel-#{channel.slug}"}
                        class="rounded px-2 py-1 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
                      >
                        Edit
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class={["min-h-0 overflow-y-auto px-4 py-4", scrollbar_classes()]}>
          <div class="rounded-xl border border-base-300 bg-base-200 p-4">
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
                  Editor
                </p>
                <h3 class="mt-1 text-base font-semibold text-base-content">{@channel_form_title}</h3>
              </div>

              <button
                :if={@editing_channel_id}
                type="button"
                phx-click="cancel_channel_edit"
                id="cancel-channel-edit"
                class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
              >
                New
              </button>
            </div>

            <.form
              for={@channel_form}
              id="channel-form"
              phx-submit="save_channel"
              class="mt-4 space-y-4"
            >
              <.input field={@channel_form[:name]} type="text" label="Name" />
              <.input field={@channel_form[:slug]} type="text" label="Slug" />

              <.input
                :if={@channel_form_mode not in [:create_category, :edit_category]}
                field={@channel_form[:topic]}
                type="textarea"
                label="Topic"
              />

              <.input
                :if={@channel_form_mode not in [:create_category, :edit_category]}
                field={@channel_form[:parent_channel_id]}
                type="select"
                label="Category"
                prompt="No category"
                options={Enum.map(manageable_categories(@all_channel_sections), &{&1.name, &1.id})}
              />

              <.input
                :if={@channel_form_mode not in [:create_category, :edit_category]}
                field={@channel_form[:nsfw]}
                type="checkbox"
                label="Mark channel as age-gated"
              />

              <div class="flex items-center justify-between gap-3 pt-2">
                <button
                  :if={@editing_channel_id}
                  type="button"
                  phx-click="delete_channel"
                  phx-value-id={@editing_channel_id}
                  id="delete-channel"
                  class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-rose-300 transition hover:bg-rose-500/10 hover:text-rose-100"
                >
                  Delete
                </button>

                <div class="ml-auto flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="close_manage_channels"
                    class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
                  >
                    Close
                  </button>
                  <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-violet-400">
                    Save
                  </.button>
                </div>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </aside>
    """
  end

  def emoji_manager(assigns) do
    ~H"""
    <div
      :if={@can_manage_emojis?}
      id="emoji-manager-overlay"
      class={[
        "fixed inset-0 z-40 bg-black/70 transition",
        @manage_emojis_open? && "opacity-100 pointer-events-auto",
        !@manage_emojis_open? && "pointer-events-none opacity-0"
      ]}
      phx-click="close_manage_emojis"
    />

    <aside
      :if={@can_manage_emojis?}
      id="emoji-manager-panel"
      aria-hidden={if(@manage_emojis_open?, do: "false", else: "true")}
      class={[
        "fixed inset-y-0 right-0 z-50 flex w-full max-w-lg flex-col border-l border-base-300 bg-base-100 shadow-2xl transition-transform duration-200 ease-out lg:shadow-2xl",
        !@manage_emojis_open? && "shadow-none lg:shadow-[-16px_0_48px_rgba(0,0,0,0.45)]",
        @manage_emojis_open? && "pointer-events-auto",
        !@manage_emojis_open? && "pointer-events-none",
        @manage_emojis_open? && "translate-x-0",
        !@manage_emojis_open? && "translate-x-full"
      ]}
    >
      <div class="flex items-center justify-between border-b border-base-300 px-5 py-4">
        <div>
          <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-base-content/50">
            Server assets
          </p>
          <h2 class="mt-1 text-lg font-semibold text-base-content">Custom emoji</h2>
        </div>

        <button
          type="button"
          phx-click="close_manage_emojis"
          id="close-emoji-manager"
          class="rounded-md px-2 py-1 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          Close
        </button>
      </div>

      <div class="grid min-h-0 flex-1 gap-0 lg:grid-cols-[1.05fr_0.95fr]">
        <div class={[
          "min-h-0 overflow-y-auto border-b border-base-300 px-4 py-4 lg:border-b-0 lg:border-r",
          scrollbar_classes()
        ]}>
          <div class="flex items-center justify-between gap-3">
            <div>
              <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
                Library
              </p>
              <p class="mt-1 text-xs text-base-content/70">
                Upload small reaction-ready emoji assets.
              </p>
            </div>
            <span class="rounded bg-base-300 px-2 py-1 text-[10px] font-semibold text-base-content/70">
              {length(@custom_emojis)} total
            </span>
          </div>

          <div class="mt-4 grid gap-3 sm:grid-cols-2">
            <div
              :for={emoji <- @custom_emojis}
              id={"manage-emoji-#{emoji.id}"}
              class="rounded-xl border border-base-300 bg-base-200 p-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="flex min-w-0 items-center gap-3">
                  <img
                    src={emoji.url}
                    alt={emoji.name}
                    class="size-10 rounded-lg bg-base-300 object-cover"
                  />
                  <div class="min-w-0">
                    <p class="truncate text-sm font-semibold text-base-content">{emoji.name}</p>
                    <p class="truncate text-[11px] text-base-content/70">{emoji.shortcode}</p>
                  </div>
                </div>

                <button
                  type="button"
                  phx-click="delete_emoji"
                  phx-value-id={emoji.id}
                  id={"delete-emoji-#{emoji.id}"}
                  class="rounded px-2 py-1 text-[11px] font-semibold text-rose-300 transition hover:bg-rose-500/10 hover:text-rose-100"
                >
                  Delete
                </button>
              </div>
            </div>
          </div>
        </div>

        <div class={["min-h-0 overflow-y-auto px-4 py-4", scrollbar_classes()]}>
          <div class="rounded-xl border border-base-300 bg-base-200 p-4">
            <div>
              <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
                Upload
              </p>
              <h3 class="mt-1 text-base font-semibold text-base-content">Add custom emoji</h3>
            </div>

            <.form for={@emoji_form} id="emoji-form" phx-submit="save_emoji" class="mt-4 space-y-4">
              <.input field={@emoji_form[:name]} type="text" label="Name" />
              <.input field={@emoji_form[:shortcode]} type="text" label="Shortcode" />

              <div>
                <label class="mb-2 block text-sm font-medium text-base-content/85">Image</label>
                <div class="rounded-xl border border-dashed border-base-300 bg-base-100 p-4">
                  <.live_file_input
                    upload={@uploads.emoji_image}
                    class="block w-full text-sm text-base-content/85"
                  />
                  <p class="mt-2 text-[11px] text-base-content/50">
                    png, jpg, gif, or webp. keep it tiny.
                  </p>
                </div>
                <p
                  :for={err <- upload_errors(@uploads.emoji_image)}
                  class="mt-2 text-[11px] text-rose-300"
                >
                  {emoji_upload_error(err)}
                </p>
              </div>

              <div class="flex items-center justify-end gap-2 pt-2">
                <button
                  type="button"
                  phx-click="close_manage_emojis"
                  class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
                >
                  Close
                </button>
                <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-violet-400">
                  Save emoji
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </aside>
    """
  end
end
