defmodule RfchatWeb.SettingsComponents.Server do
  @moduledoc false

  use RfchatWeb, :html

  alias Rfchat.Accounts
  alias Rfchat.Chat

  import RfchatWeb.SettingsComponents.Helpers

  def server_tab(assigns) do
    ~H"""
    <div id="settings-view-server">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Server management
      </p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Channels, emoji, moderation</h2>

      <div class="mt-5 rounded-xl border border-base-300 bg-base-200 p-4">
        <div class="flex items-start justify-between gap-4">
          <div>
            <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
              Branding
            </p>
            <h3 class="mt-1 text-base font-semibold text-base-content">Server identity</h3>
          </div>

          <%= if @server_settings.icon_asset do %>
            <img
              src={Chat.server_icon_url(@server_settings)}
              alt={@server_settings.name}
              class="size-14 rounded-2xl border border-base-300 object-cover shadow-sm"
            />
          <% else %>
            <div class="flex size-14 items-center justify-center rounded-2xl bg-primary/15 text-lg font-bold uppercase text-primary shadow-sm">
              {String.first(@server_settings.name || "R")}
            </div>
          <% end %>
        </div>

        <.form
          for={@server_settings_form}
          id="server-settings-form"
          phx-submit="save_server_settings"
          class="mt-4 space-y-4"
        >
          <.input field={@server_settings_form[:name]} type="text" label="Server name" />

          <div>
            <label class="mb-2 block text-sm font-medium text-base-content/85">Server icon</label>
            <div class="rounded-xl border border-dashed border-base-300 bg-base-100 p-4">
              <.live_file_input
                upload={@uploads.server_icon}
                class="block w-full text-sm text-base-content/85"
              />
              <p class="mt-2 text-[11px] text-base-content/50">
                Used for branding, favicon, and the custom emoji category icon.
              </p>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
              Save server settings
            </.button>

            <button
              :if={@server_settings.icon_asset}
              type="button"
              phx-click="remove_server_icon"
              id="remove-server-icon"
              class="rounded-md px-3 py-1.5 text-[11px] font-semibold text-base-content/80 transition hover:bg-base-300 hover:text-base-content"
            >
              Remove icon
            </button>
          </div>
        </.form>
      </div>

      <div class="mt-5 flex flex-wrap gap-2">
        <button
          :if={@can_manage_channels?}
          type="button"
          phx-click="toggle_manage_channels"
          id="open-channel-manager"
          class="rounded-md bg-violet-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-violet-400"
        >
          Manage channels
        </button>

        <button
          :if={@can_manage_emojis?}
          type="button"
          phx-click="toggle_manage_emojis"
          id="open-emoji-manager"
          class="rounded-md bg-violet-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-violet-400"
        >
          Manage emoji
        </button>
      </div>

      <.bot_registry :if={@can_manage_bots?} {assigns} />
      <.members_panel {assigns} />
    </div>
    """
  end

  def bot_registry(assigns) do
    ~H"""
    <div class="mt-5 rounded-xl border border-base-300 bg-base-200 p-4">
      <div class="flex items-center justify-between gap-3">
        <div>
          <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            Bots
          </p>
          <h3 class="mt-1 text-base font-semibold text-base-content">Bot registry</h3>
        </div>
        <span class="rounded bg-base-300 px-2 py-1 text-[10px] font-semibold text-base-content/60">
          {length(@bot_users)} bots
        </span>
      </div>

      <.form
        for={@bot_form}
        id="bot-form"
        phx-submit="create_bot"
        class="mt-4 grid gap-4 lg:grid-cols-2"
      >
        <.input field={@bot_form[:display_name]} type="text" label="Display name" />
        <.input field={@bot_form[:username]} type="text" label="Username" />
        <.input field={@bot_form[:email]} type="email" label="Email" />
        <.input field={@bot_form[:bio]} type="text" label="Bio" />
        <.input
          field={@bot_form[:role_ids]}
          type="select"
          label="Roles"
          multiple
          options={Enum.map(@manageable_roles, &{&1.name, &1.id})}
        />

        <div class="lg:col-span-2">
          <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
            Create bot
          </.button>
        </div>
      </.form>

      <div id="bot-registry-list" class="mt-5 space-y-3">
        <div
          :for={bot_user <- @bot_users}
          id={"bot-card-#{bot_user.id}"}
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="text-sm font-semibold text-base-content">{bot_user.display_name}</p>
              <p class="text-[11px] text-base-content/50">@{bot_user.username}</p>
              <p :if={bot_user.bio} class="mt-2 text-[11px] text-base-content/70">{bot_user.bio}</p>
            </div>

            <div class="flex flex-wrap gap-1">
              <span
                :for={member_role <- bot_user.member_roles}
                class="rounded bg-base-300 px-1.5 py-0.5 text-[10px] font-semibold text-base-content/70"
              >
                {member_role.role.name}
              </span>
            </div>
          </div>

          <div class="mt-4 grid gap-4 lg:grid-cols-[1.1fr_0.9fr]">
            <.form
              for={
                Map.get(
                  @bot_token_forms,
                  bot_user.id,
                  to_form(%{"label" => "", "expires_in_days" => ""}, as: :token)
                )
              }
              id={"bot-token-form-#{bot_user.id}"}
              phx-submit="create_bot_token"
              phx-value-id={bot_user.id}
              class="grid gap-3 md:grid-cols-2"
            >
              <% token_form =
                Map.get(
                  @bot_token_forms,
                  bot_user.id,
                  to_form(%{"label" => "", "expires_in_days" => ""}, as: :token)
                ) %>

              <.input field={token_form[:label]} type="text" label="Token label" />
              <.input
                field={token_form[:expires_in_days]}
                type="number"
                label="Expires in days"
                min="1"
              />

              <div class="md:col-span-2 flex items-center gap-3">
                <.button class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400">
                  Create token
                </.button>

                <div
                  :if={Map.get(@revealed_bot_tokens, bot_user.id)}
                  id={"revealed-bot-token-#{bot_user.id}"}
                  class="rounded-md border border-emerald-500/20 bg-emerald-500/10 px-3 py-1.5 text-[11px] text-emerald-100"
                >
                  {Map.get(@revealed_bot_tokens, bot_user.id)}
                </div>
              </div>
            </.form>

            <div class="space-y-2">
              <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
                Tokens
              </p>

              <div
                :for={token <- bot_user.bot_tokens}
                id={"bot-token-row-#{token.id}"}
                class="rounded-lg border border-base-300 bg-base-200 px-3 py-2"
              >
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <p class="text-[11px] font-semibold text-base-content">
                      {token.label || "Unnamed token"}
                    </p>
                    <p class="text-[10px] text-base-content/50">
                      {if token.revoked_at, do: "revoked", else: "active"}
                      <%= if token.expires_at do %>
                        · expires {Calendar.strftime(token.expires_at, "%b %-d")}
                      <% end %>
                    </p>
                  </div>

                  <button
                    :if={is_nil(token.revoked_at)}
                    type="button"
                    phx-click="revoke_bot_token"
                    phx-value-id={token.id}
                    id={"revoke-bot-token-#{token.id}"}
                    class="rounded-md px-2.5 py-1 text-[11px] font-semibold text-rose-300 transition hover:bg-rose-500/10 hover:text-rose-100"
                  >
                    Revoke
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def members_panel(assigns) do
    ~H"""
    <div class="mt-5 rounded-xl border border-base-300 bg-base-200 p-4">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Members
      </p>

      <div id="settings-member-list" class="mt-3 space-y-2">
        <div
          :for={entry <- @member_presence}
          id={"member-presence-#{entry.user.id}"}
          class="rounded-lg border border-base-300 bg-base-100 p-3"
        >
          <div class="flex items-start gap-3">
            <span class={[
              "mt-1 inline-block size-2.5 rounded-full",
              member_status_class(entry.status)
            ]} />

            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <p class="truncate text-sm font-medium text-base-content">
                  {entry.user.display_name}
                </p>
                <span
                  :if={entry.user.membership.is_owner}
                  class="inline-flex rounded bg-indigo-500/20 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em] text-indigo-300"
                >
                  Owner
                </span>
              </div>
              <p class="truncate text-[11px] text-base-content/50">@{entry.user.username}</p>
              <p class="mt-1 text-[11px] text-base-content/70">
                {member_status_label(entry.status)} · {Calendar.strftime(
                  entry.last_active_at,
                  "%b %-d · %H:%M"
                )}
              </p>

              <span
                :if={member_timeout_label(entry)}
                class="mt-2 inline-flex rounded bg-amber-500/15 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.16em] text-amber-200"
              >
                timed out until {member_timeout_label(entry)}
              </span>

              <div
                :if={entry.user.id != @current_user.id && Accounts.owner?(@current_user)}
                class="mt-2"
              >
                <button
                  :if={!entry.user.membership.is_owner}
                  type="button"
                  phx-click="promote_to_owner"
                  phx-value-id={entry.user.id}
                  id={"promote-owner-#{entry.user.id}"}
                  data-confirm={"Promote #{entry.user.display_name} to owner? They will have full server control."}
                  class="rounded-md border border-indigo-500/30 bg-indigo-500/10 px-2.5 py-1 text-[11px] font-semibold text-indigo-300 transition hover:border-indigo-400/40 hover:bg-indigo-500/20"
                >
                  Promote to owner
                </button>

                <button
                  :if={entry.user.membership.is_owner}
                  type="button"
                  phx-click="demote_from_owner"
                  phx-value-id={entry.user.id}
                  id={"demote-owner-#{entry.user.id}"}
                  data-confirm={"Remove owner status from #{entry.user.display_name}?"}
                  class="rounded-md border border-zinc-500/30 bg-zinc-500/10 px-2.5 py-1 text-[11px] font-semibold text-zinc-400 transition hover:border-zinc-400/40 hover:bg-zinc-500/20"
                >
                  Demote from owner
                </button>
              </div>

              <button
                :if={
                  @can_moderate_members? && !entry.user.membership.is_owner &&
                    entry.user.id != @current_user.id
                }
                type="button"
                phx-click="toggle_member_actions"
                phx-value-id={entry.user.id}
                id={"open-member-actions-#{entry.user.id}"}
                class="mt-3 rounded-md border border-base-300 px-2.5 py-1 text-[11px] font-semibold text-base-content/80 transition hover:border-base-content/20 hover:bg-base-200 hover:text-base-content"
              >
                Moderate
              </button>

              <div
                :if={selected_member(entry, @member_action_user_id)}
                id={"member-actions-#{entry.user.id}"}
                class="mt-3 rounded-xl border border-base-300 bg-base-200 p-3"
              >
                <.form
                  for={@member_action_form}
                  id={"member-action-form-#{entry.user.id}"}
                  phx-submit="moderate_member"
                  class="space-y-3"
                >
                  <input type="hidden" name="user_id" value={entry.user.id} />

                  <.input
                    field={@member_action_form[:action]}
                    type="select"
                    label="Action"
                    options={[{"Timeout", "timeout"}, {"Kick", "kick"}, {"Ban", "ban"}]}
                  />
                  <.input
                    field={@member_action_form[:duration_minutes]}
                    type="number"
                    label="Timeout minutes"
                    min="1"
                  />
                  <.input field={@member_action_form[:reason]} type="text" label="Reason" />

                  <div class="flex flex-wrap items-center gap-2">
                    <button
                      :if={member_action_available?(@current_user, entry, :moderate_members)}
                      type="submit"
                      class="rounded-md bg-amber-500 px-3 py-1.5 text-[11px] font-semibold text-black transition hover:bg-amber-400"
                      name="moderation[action]"
                      value="timeout"
                    >
                      Timeout
                    </button>

                    <button
                      :if={member_action_available?(@current_user, entry, :kick_members)}
                      type="submit"
                      class="rounded-md bg-orange-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-orange-400"
                      name="moderation[action]"
                      value="kick"
                    >
                      Kick
                    </button>

                    <button
                      :if={member_action_available?(@current_user, entry, :ban_members)}
                      type="submit"
                      class="rounded-md bg-rose-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-rose-400"
                      name="moderation[action]"
                      value="ban"
                    >
                      Ban
                    </button>
                  </div>
                </.form>

                <div class="mt-4 border-t border-base-300 pt-3">
                  <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-base-content/50">
                    Recent cases
                  </p>

                  <div :if={@moderation_cases != []} class="mt-2 space-y-2">
                    <div
                      :for={moderation_case <- Enum.take(@moderation_cases, 5)}
                      class="rounded-lg border border-base-300 bg-base-100 px-3 py-2"
                    >
                      <div class="flex items-center justify-between gap-2">
                        <p class="text-[11px] font-semibold text-base-content">
                          {moderation_case_label(moderation_case.action_type)}
                        </p>
                        <p class="text-[10px] text-base-content/50">
                          Case #{moderation_case.case_number}
                        </p>
                      </div>
                      <p class="mt-1 text-[11px] text-base-content/70">
                        by {moderation_case.actor_user && moderation_case.actor_user.display_name}
                      </p>
                      <p :if={moderation_case.reason} class="mt-1 text-[11px] text-base-content/80">
                        {moderation_case.reason}
                      </p>
                    </div>
                  </div>

                  <p :if={@moderation_cases == []} class="mt-2 text-xs text-base-content/50">
                    No moderation cases yet.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
