defmodule TavernWeb.SettingsComponents.Roles do
  @moduledoc false

  use TavernWeb, :html

  import Bitwise

  alias Tavern.Chat.PermissionBits
  import TavernWeb.SettingsComponents.Helpers

  @permission_groups [
    {"General",
     [
       :view_channel,
       :manage_channels,
       :manage_roles,
       :manage_emojis_and_stickers,
       :manage_webhooks,
       :manage_events,
       :manage_bots,
       :manage_server,
       :view_audit_log
     ]},
    {"Text",
     [
       :send_messages,
       :send_messages_in_threads,
       :create_public_threads,
       :create_private_threads,
       :embed_links,
       :attach_files,
       :add_reactions,
       :use_external_emojis,
       :use_external_stickers,
       :mention_everyone,
       :manage_messages
     ]},
    {"Moderation", [:moderate_members, :kick_members, :ban_members]},
    {"Admin", [:administrator]}
  ]

  def roles_tab(assigns) do
    ~H"""
    <div id="settings-view-roles">
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">Roles</p>
      <h2 class="mt-1 text-xl font-semibold text-base-content">Roles and permissions</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Higher roles outrank lower ones. You can change only roles below your highest role.
      </p>

      <.form
        for={@new_role_form}
        id="role-create-form"
        phx-submit="create_role"
        class="mt-5 flex flex-wrap items-end gap-3 rounded-xl border border-base-300 bg-base-200 p-4"
      >
        <div class="min-w-48 flex-1">
          <.input field={@new_role_form[:name]} type="text" label="New role name" />
        </div>
        <div class="w-24">
          <.input
            field={@new_role_form[:color]}
            type="color"
            label="Color"
            value={color_value(@new_role_form[:color].value)}
            class="h-10 w-full cursor-pointer rounded-lg border border-base-300 bg-base-100"
          />
        </div>
        <button
          type="submit"
          id="create-role-button"
          class="mb-2 inline-flex items-center gap-1.5 rounded-md bg-violet-500 px-3 py-2 text-xs font-semibold text-white transition hover:bg-violet-400 active:scale-[0.98]"
        >
          <.icon name="hero-plus" class="size-4" /> Create role
        </button>
      </.form>

      <div class="mt-5 grid gap-5 xl:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
        <ol id="role-list" class="space-y-2">
          <li
            :for={{role, index} <- Enum.with_index(@roles)}
            id={"role-row-#{role.id}"}
            class={[
              "group flex items-center gap-3 rounded-xl border bg-base-100 px-3 py-2.5 transition",
              if(@editing_role_id == role.id,
                do: "border-primary/50 ring-1 ring-primary/30",
                else: "border-base-300 hover:border-base-content/20"
              )
            ]}
          >
            <span
              class="size-3 shrink-0 rounded-full ring-2 ring-base-300"
              style={"background-color: #{color_hex(role.color)}"}
            />
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-semibold text-base-content">{role.name}</p>
              <p class="text-[11px] text-base-content/50">
                {role.member_count} {if role.member_count == 1, do: "member", else: "members"}
                <span :if={role.is_default}>· default</span>
                <span :if={role.managed and not role.is_default}>· managed</span>
              </p>
            </div>

            <div
              :if={MapSet.member?(@role_controls.manageable_role_ids, role.id)}
              class="flex items-center gap-1"
            >
              <%= if movable?(role) do %>
                <button
                  type="button"
                  id={"move-role-up-#{role.id}"}
                  phx-click="move_role"
                  phx-value-id={role.id}
                  phx-value-direction="up"
                  disabled={index == 0}
                  aria-label={"Move #{role.name} up"}
                  class="rounded-md p-1 text-base-content/60 transition hover:bg-base-200 hover:text-base-content disabled:opacity-30"
                >
                  <.icon name="hero-chevron-up" class="size-4" />
                </button>
                <button
                  type="button"
                  id={"move-role-down-#{role.id}"}
                  phx-click="move_role"
                  phx-value-id={role.id}
                  phx-value-direction="down"
                  disabled={lowest_movable?(@roles, index)}
                  aria-label={"Move #{role.name} down"}
                  class="rounded-md p-1 text-base-content/60 transition hover:bg-base-200 hover:text-base-content disabled:opacity-30"
                >
                  <.icon name="hero-chevron-down" class="size-4" />
                </button>
              <% end %>
              <button
                type="button"
                id={"edit-role-#{role.id}"}
                phx-click="edit_role"
                phx-value-id={role.id}
                aria-label={"Edit #{role.name}"}
                class="rounded-md p-1 text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </button>
              <button
                :if={movable?(role)}
                type="button"
                id={"delete-role-#{role.id}"}
                phx-click="delete_role"
                phx-value-id={role.id}
                data-confirm={"Delete #{role.name}? Members lose it at once."}
                aria-label={"Delete #{role.name}"}
                class="rounded-md p-1 text-rose-400 transition hover:bg-rose-500/10 hover:text-rose-300"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </li>
        </ol>

        <.role_editor
          :if={@role_form}
          role={Enum.find(@roles, &(&1.id == @editing_role_id))}
          form={@role_form}
          grantable={@role_controls.grantable_permissions}
        />
      </div>
    </div>
    """
  end

  attr :role, :any, required: true
  attr :form, :any, required: true
  attr :grantable, :integer, required: true

  def role_editor(assigns) do
    assigns =
      assigns
      |> assign(:groups, @permission_groups)
      |> assign(:permissions, Phoenix.HTML.Form.input_value(assigns.form, :permissions) || 0)

    ~H"""
    <.form
      for={@form}
      id="role-edit-form"
      phx-submit="save_role"
      class="space-y-4 rounded-xl border border-base-300 bg-base-200 p-4"
    >
      <div class="flex items-center justify-between gap-3">
        <h3 class="text-base font-semibold text-base-content">Edit {@role && @role.name}</h3>
        <button
          type="button"
          id="cancel-role-edit"
          phx-click="cancel_role_edit"
          class="rounded-md p-1 text-base-content/60 transition hover:bg-base-300 hover:text-base-content"
          aria-label="Close editor"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <div :if={@role && !@role.is_default} class="grid gap-3 sm:grid-cols-[1fr_6rem]">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input
          field={@form[:color]}
          type="color"
          label="Color"
          value={color_value(@form[:color].value)}
          class="h-10 w-full cursor-pointer rounded-lg border border-base-300 bg-base-100"
        />
        <.input field={@form[:mentionable]} type="checkbox" label="Anyone can mention" />
        <.input field={@form[:hoist]} type="checkbox" label="Show separately in member list" />
      </div>

      <div id="role-permission-grid" class="space-y-3">
        <fieldset
          :for={{group, flags} <- @groups}
          id={"role-permission-group-#{String.downcase(group)}"}
          class="rounded-lg border border-base-300 bg-base-100 p-3"
        >
          <legend class="px-1 text-[10px] font-bold uppercase tracking-[0.18em] text-base-content/50">
            {group}
          </legend>
          <div class="grid gap-x-4 sm:grid-cols-2">
            <.input
              :for={flag <- flags}
              type="checkbox"
              id={"role-permission-#{flag}"}
              name={"role[permissions][#{flag}]"}
              label={permission_label(flag)}
              checked={bit?(@permissions, flag)}
              disabled={not bit?(@grantable, flag)}
            />
          </div>
        </fieldset>
      </div>

      <button
        type="submit"
        id="save-role-button"
        class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400 active:scale-[0.98]"
      >
        Save role
      </button>
    </.form>
    """
  end

  defp movable?(role), do: not role.is_default and not role.managed

  # The default role is last and never moves, so the role just above it cannot move down.
  defp lowest_movable?(roles, index) do
    case Enum.at(roles, index + 1) do
      nil -> true
      next -> next.is_default
    end
  end

  defp bit?(bits, flag) when is_integer(bits) do
    bit = PermissionBits.flag(flag)
    band(bits, bit) == bit
  end

  defp bit?(_bits, _flag), do: false

  defp color_value("#" <> _ = hex), do: hex
  defp color_value(color), do: color_hex(color)

  defp permission_label(flag) do
    flag |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end
end
