defmodule TavernWeb.SettingsLive.Roles do
  @moduledoc """
  The Roles tab and the member role controls of SettingsLive. The context decides every write;
  a refusal becomes a flash.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias Tavern.Chat.PermissionBits
  alias Tavern.Chat.Role

  @events ~w(create_role edit_role cancel_role_edit save_role move_role delete_role
             toggle_member_roles add_member_role remove_member_role)

  # Form keys to flag atoms, so input never creates atoms.
  @flags_by_name Map.new(PermissionBits.flags(), fn {name, _bit} -> {to_string(name), name} end)

  def events, do: @events

  def init(socket) do
    socket
    |> assign(:editing_role_id, nil)
    |> assign(:role_form, nil)
    |> assign(:new_role_form, new_role_form())
    |> assign(:member_roles_user_id, nil)
    |> assign(:member_roles, [])
    |> refresh()
  end

  @doc "Re-reads the roles and what the scope may do with them."
  def refresh(socket) do
    scope = socket.assigns.current_scope
    controls = Chat.role_controls(scope)
    roles = Chat.list_roles(scope)

    editing_role =
      socket.assigns.editing_role_id &&
        Enum.find(roles, &(&1.id == socket.assigns.editing_role_id))

    socket
    |> assign(:roles, roles)
    |> assign(:role_controls, controls)
    |> assign(:editing_role_id, editing_role && editing_role.id)
    |> assign(:role_form, editing_role && role_form(Chat.change_role(editing_role)))
    |> assign(:member_roles, member_roles(scope, socket.assigns.member_roles_user_id))
  end

  def handle_event("create_role", %{"role_create" => params}, socket) do
    case Chat.create_role(socket.assigns.current_scope, role_attrs(params)) do
      {:ok, role} ->
        {:noreply,
         socket
         |> assign(:new_role_form, new_role_form())
         |> assign(:editing_role_id, role.id)
         |> refresh()
         |> put_flash(:info, "Role #{role.name} created.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :new_role_form, to_form(changeset, as: :role_create))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("edit_role", %{"id" => role_id}, socket) do
    case Enum.find(socket.assigns.roles, &(&1.id == role_id)) do
      %Role{} = role ->
        {:noreply,
         socket
         |> assign(:editing_role_id, role.id)
         |> assign(:role_form, role_form(Chat.change_role(role)))}

      nil ->
        {:noreply, refusal(socket, :not_found)}
    end
  end

  def handle_event("cancel_role_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_role_id, nil) |> assign(:role_form, nil)}
  end

  def handle_event("save_role", %{"role" => params}, socket) do
    scope = socket.assigns.current_scope

    case Chat.update_role(scope, socket.assigns.editing_role_id, role_attrs(params)) do
      {:ok, role} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Role #{role.name} saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :role_form, role_form(changeset))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("move_role", %{"id" => role_id, "direction" => direction}, socket) do
    case Chat.move_role(socket.assigns.current_scope, role_id, direction) do
      {:ok, _role} -> {:noreply, refresh(socket)}
      {:error, reason} -> {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("delete_role", %{"id" => role_id}, socket) do
    case Chat.delete_role(socket.assigns.current_scope, role_id) do
      {:ok, role} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Role #{role.name} deleted.")}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("toggle_member_roles", %{"id" => user_id}, socket) do
    next_user_id = if socket.assigns.member_roles_user_id == user_id, do: nil, else: user_id

    {:noreply,
     socket
     |> assign(:member_roles_user_id, next_user_id)
     |> assign(:member_roles, member_roles(socket.assigns.current_scope, next_user_id))}
  end

  def handle_event("add_member_role", %{"user_id" => user_id, "member_role" => params}, socket) do
    scope = socket.assigns.current_scope

    case Chat.add_member_role(scope, user_id, Map.get(params, "role_id")) do
      {:ok, role} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Gave #{role.name}.")}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("remove_member_role", %{"user_id" => user_id, "role_id" => role_id}, socket) do
    case Chat.remove_member_role(socket.assigns.current_scope, user_id, role_id) do
      {:ok, role} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Took #{role.name}.")}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  @doc """
  Turns submitted role params into context attrs: the color from `#rrggbb` to an integer, and
  the permission checkboxes to bits. A checkbox that was disabled submits nothing and reads as
  unset; the context refuses an edit that would drop a bit the actor cannot set.
  """
  def role_attrs(params) do
    params
    |> Map.take(["name", "mentionable", "hoist"])
    |> put_color(Map.get(params, "color"))
    |> put_permissions(Map.get(params, "permissions"))
  end

  defp put_color(attrs, "#" <> hex) do
    case Integer.parse(hex, 16) do
      {color, ""} -> Map.put(attrs, "color", color)
      _ -> Map.put(attrs, "color", -1)
    end
  end

  defp put_color(attrs, _color), do: attrs

  defp put_permissions(attrs, checked) when is_map(checked) do
    names =
      for {name, "true"} <- checked, flag = Map.get(@flags_by_name, name), flag != nil, do: flag

    Map.put(attrs, "permissions", PermissionBits.combine(names))
  end

  defp put_permissions(attrs, _checked), do: attrs

  defp role_form(changeset), do: to_form(changeset, as: :role)

  defp new_role_form, do: to_form(%{"name" => "", "color" => "#99aab5"}, as: :role_create)

  defp member_roles(_scope, nil), do: []
  defp member_roles(scope, user_id), do: Chat.member_roles(scope, user_id) || []

  defp refusal(socket, :not_found),
    do: put_flash(socket, :error, "That role or member no longer exists.")

  defp refusal(socket, _forbidden),
    do: put_flash(socket, :error, "You do not have permission to do that.")
end
