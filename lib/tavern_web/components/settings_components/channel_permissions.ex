defmodule TavernWeb.SettingsComponents.ChannelPermissions do
  @moduledoc """
  The Permissions section of the channel editor: one row per overwrite, a three-way control (deny,
  inherit, allow) per channel permission, and pickers that add a role or member override.
  """

  use TavernWeb, :html

  import Bitwise

  alias Tavern.Chat.PermissionBits
  alias TavernWeb.SettingsLive.ChannelPermissions

  attr :permissions, :map, required: true
  attr :open_key, :string, default: nil
  attr :roles, :list, required: true
  attr :members, :list, required: true
  attr :role_form, :any, required: true
  attr :member_form, :any, required: true

  def section(assigns) do
    targeted = MapSet.new(assigns.permissions.rows, & &1.target)
    controls = assigns.permissions.controls

    assigns =
      assigns
      |> assign(
        :role_options,
        for(
          role <- assigns.roles,
          MapSet.member?(controls.role_ids, role.id),
          not MapSet.member?(targeted, {:role, role.id}),
          do: {if(role.is_default, do: "@everyone", else: role.name), "role:#{role.id}"}
        )
      )
      |> assign(
        :member_options,
        for(
          %{user: user} <- assigns.members,
          MapSet.member?(controls.user_ids, user.id),
          not MapSet.member?(targeted, {:user, user.id}),
          do: {user.display_name || user.username, "user:#{user.id}"}
        )
      )

    ~H"""
    <section
      id="channel-permissions"
      class="mt-4 rounded-xl border border-base-300 bg-base-200 p-4"
      aria-labelledby="channel-permissions-title"
    >
      <p class="text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        Access
      </p>
      <h3 id="channel-permissions-title" class="mt-1 text-base font-semibold text-base-content">
        Permissions
      </h3>
      <p class="mt-1 text-xs text-base-content/60">
        Overrides apply to this channel only. Deny beats a role's grant; a member override wins over both.
      </p>

      <ul id="overwrite-list" class="mt-4 space-y-2">
        <li
          :for={row <- @permissions.rows}
          id={"overwrite-row-#{row.key}"}
          class={[
            "overflow-hidden rounded-lg border bg-base-100 transition",
            if(@open_key == row.key,
              do: "border-violet-400/60 shadow-sm",
              else: "border-base-300"
            )
          ]}
        >
          <button
            type="button"
            id={"toggle-overwrite-#{row.key}"}
            phx-click="toggle_overwrite"
            phx-value-key={row.key}
            aria-expanded={to_string(@open_key == row.key)}
            class="flex w-full items-center gap-2 px-3 py-2 text-left transition hover:bg-base-200/60"
          >
            <.icon
              name={if(row.kind == :role, do: "hero-shield-check", else: "hero-user")}
              class="size-4 shrink-0 text-base-content/50"
            />
            <span class="min-w-0 flex-1 truncate text-sm font-semibold text-base-content">
              {row.label}
            </span>
            <span
              :if={count(row.allow) > 0}
              class="rounded bg-emerald-500/15 px-1.5 py-0.5 text-[10px] font-bold text-emerald-500"
            >
              +{count(row.allow)}
            </span>
            <span
              :if={count(row.deny) > 0}
              class="rounded bg-rose-500/15 px-1.5 py-0.5 text-[10px] font-bold text-rose-500"
            >
              −{count(row.deny)}
            </span>
            <span
              :if={!row.editable?}
              class="rounded bg-base-300 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-[0.14em] text-base-content/50"
            >
              Locked
            </span>
            <.icon
              name="hero-chevron-down"
              class={[
                "size-4 shrink-0 text-base-content/50 transition-transform duration-150",
                @open_key == row.key && "rotate-180"
              ]}
            />
          </button>

          <.form
            :if={@open_key == row.key}
            for={%{}}
            as={:overwrite}
            id={"overwrite-form-#{row.key}"}
            phx-submit="save_overwrite"
            class="border-t border-base-300 px-3 pb-3 pt-2"
          >
            <input
              type="hidden"
              name="overwrite[target]"
              value={ChannelPermissions.target_value(row.target)}
            />

            <div class="divide-y divide-base-300/60">
              <div
                :for={flag <- ChannelPermissions.channel_flags()}
                id={"overwrite-#{row.key}-#{flag}"}
                class="flex items-center justify-between gap-3 py-1.5"
              >
                <span class="text-xs text-base-content/85">{permission_label(flag)}</span>
                <.tri_state
                  row={row}
                  flag={flag}
                  disabled={!row.editable? or not bit?(@permissions.controls.changeable_bits, flag)}
                />
              </div>
            </div>

            <div class="mt-3 flex items-center justify-between gap-2">
              <button
                :if={row.stored? and row.editable?}
                type="button"
                id={"delete-overwrite-#{row.key}"}
                phx-click="delete_overwrite"
                phx-value-target={ChannelPermissions.target_value(row.target)}
                data-confirm={"Remove the override for #{row.label}?"}
                class="rounded-md px-2 py-1 text-[11px] font-semibold text-rose-400 transition hover:bg-rose-500/10 hover:text-rose-300"
              >
                Remove
              </button>
              <button
                :if={row.editable?}
                type="submit"
                id={"save-overwrite-#{row.key}"}
                phx-disable-with="Saving…"
                class="ml-auto rounded-md bg-violet-500 px-3 py-1.5 text-[11px] font-semibold text-white transition hover:bg-violet-400 active:scale-[0.98]"
              >
                Save
              </button>
            </div>
          </.form>
        </li>
      </ul>

      <div class="mt-4 grid gap-1">
        <.form
          for={@role_form}
          id="add-overwrite-role-form"
          phx-submit="add_overwrite"
          class="flex items-end gap-2"
        >
          <div class="min-w-0 flex-1">
            <.input
              field={@role_form[:target]}
              id="add-overwrite-role"
              type="select"
              label="Add role"
              prompt={if(@role_options == [], do: "No roles left", else: "Choose a role")}
              options={@role_options}
              disabled={@role_options == []}
            />
          </div>
          <button
            type="submit"
            id="add-overwrite-role-button"
            disabled={@role_options == []}
            aria-label="Add role override"
            class="mb-2 rounded-md bg-base-300 p-2 text-base-content/80 transition hover:bg-violet-500 hover:text-white disabled:pointer-events-none disabled:opacity-40"
          >
            <.icon name="hero-plus" class="size-4" />
          </button>
        </.form>

        <.form
          for={@member_form}
          id="add-overwrite-member-form"
          phx-submit="add_overwrite"
          class="flex items-end gap-2"
        >
          <div class="min-w-0 flex-1">
            <.input
              field={@member_form[:target]}
              id="add-overwrite-member"
              type="select"
              label="Add member"
              prompt={if(@member_options == [], do: "No members left", else: "Choose a member")}
              options={@member_options}
              disabled={@member_options == []}
            />
          </div>
          <button
            type="submit"
            id="add-overwrite-member-button"
            disabled={@member_options == []}
            aria-label="Add member override"
            class="mb-2 rounded-md bg-base-300 p-2 text-base-content/80 transition hover:bg-violet-500 hover:text-white disabled:pointer-events-none disabled:opacity-40"
          >
            <.icon name="hero-plus" class="size-4" />
          </button>
        </.form>
      </div>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :flag, :atom, required: true
  attr :disabled, :boolean, required: true

  # Three radio buttons in one segmented control. A disabled control submits nothing; the save keeps
  # the stored value of that bit.
  defp tri_state(assigns) do
    assigns = assign(assigns, :current, state(assigns.row, assigns.flag))

    ~H"""
    <div
      role="radiogroup"
      aria-label={permission_label(@flag)}
      class={[
        "inline-flex shrink-0 overflow-hidden rounded-md border border-base-300 bg-base-200",
        @disabled && "opacity-50"
      ]}
    >
      <label
        :for={{value, icon, tone, title} <- states()}
        title={title}
        class={["relative", if(@disabled, do: "cursor-not-allowed", else: "cursor-pointer")]}
      >
        <input
          type="radio"
          id={"overwrite-#{@row.key}-#{@flag}-#{value}"}
          name={"overwrite[bits][#{@flag}]"}
          value={value}
          checked={@current == value}
          disabled={@disabled}
          class="peer sr-only"
        />
        <span class={[
          "flex size-7 items-center justify-center text-base-content/40 transition-colors duration-150",
          "peer-focus-visible:ring-2 peer-focus-visible:ring-inset peer-focus-visible:ring-violet-400",
          !@disabled && "hover:bg-base-300 hover:text-base-content",
          tone
        ]}>
          <.icon name={icon} class="size-3.5" />
          <span class="sr-only">{title}</span>
        </span>
      </label>
    </div>
    """
  end

  defp states do
    [
      {"deny", "hero-x-mark", "peer-checked:bg-rose-500 peer-checked:text-white", "Deny"},
      {"inherit", "hero-slash", "peer-checked:bg-base-300 peer-checked:text-base-content",
       "Inherit"},
      {"allow", "hero-check", "peer-checked:bg-emerald-500 peer-checked:text-white", "Allow"}
    ]
  end

  defp state(row, flag) do
    cond do
      bit?(row.allow, flag) -> "allow"
      bit?(row.deny, flag) -> "deny"
      true -> "inherit"
    end
  end

  defp bit?(bits, flag) do
    bit = PermissionBits.flag(flag)
    band(bits, bit) == bit
  end

  defp count(bits) do
    Enum.count(ChannelPermissions.channel_flags(), &bit?(bits, &1))
  end

  defp permission_label(:manage_roles), do: "Manage permissions"

  defp permission_label(flag) do
    flag |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end
end
