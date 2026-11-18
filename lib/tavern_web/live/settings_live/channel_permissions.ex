defmodule TavernWeb.SettingsLive.ChannelPermissions do
  @moduledoc """
  The Permissions section of the channel editor in SettingsLive: the overwrites on the channel or
  category being edited. The context decides every write; a refusal becomes a flash.

  The section holds one row per overwrite, and always a row for the default role. Each row saves on
  its own. A permission control the actor may not change is disabled, and a disabled control
  submits nothing, so a save keeps the stored value of every bit that was not submitted.
  """

  import Bitwise
  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias TavernWeb.SettingsLive.Roles
  alias TavernWeb.SettingsLive.State

  @events ~w(toggle_overwrite add_overwrite save_overwrite delete_overwrite)

  # The bits an overwrite acts on in a channel, in display order. The other bits are server-wide:
  # a save keeps whatever is stored for them.
  @channel_flags [
    :view_channel,
    :manage_roles,
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
  ]

  # Form keys to flag atoms, so input never creates atoms.
  @flags_by_name Map.new(@channel_flags, &{to_string(&1), &1})

  def events, do: @events
  def channel_flags, do: @channel_flags

  def init(socket) do
    socket
    |> assign(:channel_permissions, nil)
    |> assign(:open_overwrite_key, nil)
    |> assign(:overwrite_role_form, to_form(%{"target" => ""}, as: :overwrite_role))
    |> assign(:overwrite_member_form, to_form(%{"target" => ""}, as: :overwrite_member))
  end

  @doc """
  Re-reads the section for the channel being edited. It is empty when no channel is being edited
  or the scope may not manage that channel's permissions.
  """
  def refresh(socket) do
    scope = socket.assigns.current_scope

    permissions =
      with channel_id when is_binary(channel_id) <- socket.assigns.editing_channel_id,
           {:ok, overwrites} <- Chat.list_overwrites(scope, channel_id) do
        controls = Chat.overwrite_controls(scope, channel_id)

        %{
          channel_id: channel_id,
          rows: rows(overwrites, socket.assigns.roles, controls),
          controls: controls
        }
      else
        _none -> nil
      end

    assign(socket, :channel_permissions, permissions)
  end

  def handle_event("toggle_overwrite", %{"key" => key}, socket) do
    next = if socket.assigns.open_overwrite_key == key, do: nil, else: key
    {:noreply, assign(socket, :open_overwrite_key, next)}
  end

  def handle_event("add_overwrite", params, socket) do
    target_param =
      get_in(params, ["overwrite_role", "target"]) ||
        get_in(params, ["overwrite_member", "target"])

    with {:ok, target} <- parse_target(target_param),
         {:ok, _overwrite} <- put(socket, target, {0, 0}) do
      {:noreply,
       socket
       |> assign(:open_overwrite_key, row_key(target))
       |> after_write()
       |> put_flash(:info, "Override added.")}
    else
      {:error, reason} -> {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event(
        "save_overwrite",
        %{"overwrite" => %{"target" => target_param} = params},
        socket
      ) do
    with {:ok, target} <- parse_target(target_param),
         %{} = row <- find_row(socket, target),
         {:ok, _overwrite} <-
           put(socket, target, submitted_bits(row, Map.get(params, "bits", %{}))) do
      {:noreply, socket |> after_write() |> put_flash(:info, "Permissions saved.")}
    else
      nil -> {:noreply, refusal(socket, :not_found)}
      {:error, reason} -> {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("delete_overwrite", %{"target" => target_param}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, target} <- parse_target(target_param),
         %{channel_id: channel_id} <- socket.assigns.channel_permissions,
         {:ok, _overwrite} <- Chat.delete_overwrite(scope, channel_id, target) do
      {:noreply,
       socket
       |> assign(:open_overwrite_key, nil)
       |> after_write()
       |> put_flash(:info, "Override removed.")}
    else
      nil -> {:noreply, refusal(socket, :not_found)}
      {:error, reason} -> {:noreply, refusal(socket, reason)}
    end
  end

  @doc """
  The `{allow, deny}` a row's save stores: the stored bits, with each submitted channel bit set to
  allow, inherit or deny. A bit that was not submitted keeps its stored value.
  """
  def submitted_bits(%{allow: allow, deny: deny}, submitted) when is_map(submitted) do
    Enum.reduce(submitted, {allow, deny}, fn {name, state}, {allow, deny} ->
      case Map.fetch(@flags_by_name, name) do
        {:ok, flag} -> set_bit({allow, deny}, PermissionBits.flag(flag), state)
        :error -> {allow, deny}
      end
    end)
  end

  # --- Helpers -----------------------------------------------------------------------------------

  defp put(socket, target, {allow, deny}) do
    case socket.assigns.channel_permissions do
      %{channel_id: channel_id} ->
        Chat.put_overwrite(socket.assigns.current_scope, channel_id, target, allow, deny)

      nil ->
        {:error, :not_found}
    end
  end

  # Other views hear `:roles_changed`; this one wrote it, so it re-reads what that event re-reads.
  defp after_write(socket) do
    socket
    |> Roles.refresh()
    |> State.refresh_channels()
    |> refresh()
  end

  defp set_bit({allow, deny}, bit, "allow"), do: {allow ||| bit, band(deny, bnot(bit))}
  defp set_bit({allow, deny}, bit, "deny"), do: {band(allow, bnot(bit)), deny ||| bit}

  defp set_bit({allow, deny}, bit, "inherit"),
    do: {band(allow, bnot(bit)), band(deny, bnot(bit))}

  defp set_bit(bits, _bit, _state), do: bits

  # The default role's row comes first and is shown even when nothing is stored for it.
  defp rows(overwrites, roles, controls) do
    stored = Enum.map(overwrites, &row(&1, controls))

    case Enum.find(roles, & &1.is_default) do
      nil ->
        stored

      default_role ->
        if Enum.any?(stored, &(&1.target == {:role, default_role.id})),
          do: stored,
          else: [blank_row(default_role, controls) | stored]
    end
  end

  defp row(%{role: %{} = role} = overwrite, controls) do
    %{
      target: {:role, role.id},
      key: row_key({:role, role.id}),
      label: role_label(role),
      kind: :role,
      allow: overwrite.allow_permissions,
      deny: overwrite.deny_permissions,
      stored?: true,
      editable?: MapSet.member?(controls.role_ids, role.id)
    }
  end

  defp row(%{user: %{} = user} = overwrite, controls) do
    %{
      target: {:user, user.id},
      key: row_key({:user, user.id}),
      label: user.display_name || user.username,
      kind: :user,
      allow: overwrite.allow_permissions,
      deny: overwrite.deny_permissions,
      stored?: true,
      editable?: MapSet.member?(controls.user_ids, user.id)
    }
  end

  defp blank_row(default_role, controls) do
    %{
      target: {:role, default_role.id},
      key: row_key({:role, default_role.id}),
      label: role_label(default_role),
      kind: :role,
      allow: 0,
      deny: 0,
      stored?: false,
      editable?: MapSet.member?(controls.role_ids, default_role.id)
    }
  end

  defp role_label(%{is_default: true}), do: "@everyone"
  defp role_label(role), do: role.name

  defp find_row(socket, target) do
    case socket.assigns.channel_permissions do
      %{rows: rows} -> Enum.find(rows, &(&1.target == target))
      nil -> nil
    end
  end

  @doc "The DOM-safe key of a row: `role-<id>` or `user-<id>`."
  def row_key({kind, id}), do: "#{kind}-#{id}"

  @doc "The form value that names a target: `role:<id>` or `user:<id>`."
  def target_value({kind, id}), do: "#{kind}:#{id}"

  defp parse_target("role:" <> id), do: {:ok, {:role, id}}
  defp parse_target("user:" <> id), do: {:ok, {:user, id}}
  defp parse_target(_value), do: {:error, :not_found}

  defp refusal(socket, :not_found),
    do: put_flash(socket, :error, "That channel, role or member no longer exists.")

  defp refusal(socket, %Ecto.Changeset{}),
    do: put_flash(socket, :error, "Those permissions cannot be saved.")

  defp refusal(socket, _forbidden),
    do: put_flash(socket, :error, "You do not have permission to do that.")
end
