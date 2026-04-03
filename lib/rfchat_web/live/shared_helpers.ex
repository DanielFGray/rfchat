defmodule RfchatWeb.Live.SharedHelpers do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Rfchat.Chat
  alias Rfchat.Chat.Authorization

  def can_manage_channels?(nil), do: false

  def can_manage_channels?(scope) do
    permissions = scope_permissions(scope)

    Authorization.has_permission?(permissions, :manage_channels) or
      Authorization.has_permission?(permissions, :administrator)
  end

  def can_manage_emojis?(nil), do: false

  def can_manage_emojis?(scope) do
    permissions = scope_permissions(scope)

    Authorization.has_permission?(permissions, :manage_emojis_and_stickers) or
      Authorization.has_permission?(permissions, :administrator)
  end

  def can_moderate_members?(nil), do: false

  def can_moderate_members?(scope) do
    permissions = scope_permissions(scope)

    Authorization.has_permission?(permissions, :moderate_members) or
      Authorization.has_permission?(permissions, :kick_members) or
      Authorization.has_permission?(permissions, :ban_members) or
      Authorization.has_permission?(permissions, :administrator)
  end

  def scope_permissions(%{
        base_permissions: base_permissions,
        membership: membership,
        roles: roles
      }) do
    role_permissions = Enum.reduce(roles || [], 0, &Bitwise.bor(&1.permissions, &2))

    cond do
      membership && membership.is_owner ->
        Authorization.all_permissions()

      Authorization.has_permission?(base_permissions || 0, :administrator) ->
        Authorization.all_permissions()

      Authorization.has_permission?(role_permissions, :administrator) ->
        Authorization.all_permissions()

      true ->
        Bitwise.bor(base_permissions || 0, role_permissions)
    end
  end

  def channel_sections_for_manager(true), do: Chat.list_channel_tree()
  def channel_sections_for_manager(false), do: []

  def move_channel(channel_id, direction) do
    sections = Chat.list_channel_tree()

    case swap_in_sections(sections, channel_id, direction) do
      {:ok, updated_sections} ->
        case Chat.reorder_channels(updated_sections) do
          {:ok, _channels} -> :ok
          _ -> :error
        end

      :error ->
        :error
    end
  end

  def save_emoji(socket, emoji_params, refresh_fun) when is_function(refresh_fun, 1) do
    upload = uploaded_entry(socket, :emoji_image)

    if is_nil(upload) do
      {:noreply, put_flash(socket, :error, "Choose an image before saving the emoji.")}
    else
      case consume_emoji_upload(socket, emoji_params) do
        {:ok, _emoji, socket} ->
          {:noreply,
           socket
           |> refresh_fun.()
           |> assign(:emoji_form, to_form(Chat.change_emoji(%Chat.Emoji{}, %{}), as: :emoji))
           |> put_flash(:info, "Emoji added.")}

        {:error, :invalid_upload_type, socket} ->
          {:noreply, put_flash(socket, :error, "Emoji uploads must be png, jpg, gif, or webp.")}

        {:error, changeset, socket} ->
          {:noreply, assign(socket, :emoji_form, to_form(changeset, as: :emoji))}
      end
    end
  end

  def consume_emoji_upload(socket, emoji_params) do
    result =
      Phoenix.LiveView.consume_uploaded_entries(socket, :emoji_image, fn %{path: path}, entry ->
        {:ok,
         Chat.create_custom_emoji_from_upload(emoji_params, socket.assigns.current_user, %{
           path: path,
           client_name: entry.client_name,
           client_type: entry.client_type
         })}
      end)

    case result do
      [{:ok, emoji}] -> {:ok, emoji, socket}
      [{:error, reason}] -> {:error, reason, socket}
      [] -> {:error, :invalid_upload_type, socket}
    end
  end

  def uploaded_entry(socket, name) do
    socket.assigns.uploads[name].entries |> List.first()
  end

  def run_member_moderation(actor, subject, %{
        "action" => "timeout",
        "duration_minutes" => minutes,
        "reason" => reason
      }) do
    case Integer.parse(to_string(minutes || "")) do
      {duration_minutes, ""} when duration_minutes > 0 ->
        case Chat.timeout_member(actor, subject, duration_minutes, blank_to_nil(reason)) do
          {:ok, updated_subject, moderation_case} ->
            {:ok, updated_subject, moderation_case, "Member timed out."}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :invalid_duration}
    end
  end

  def run_member_moderation(actor, subject, %{"action" => "kick", "reason" => reason}) do
    case Chat.kick_member(actor, subject, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        {:ok, updated_subject, moderation_case, "Member kicked."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_member_moderation(actor, subject, %{"action" => "ban", "reason" => reason}) do
    case Chat.ban_member(actor, subject, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        {:ok, updated_subject, moderation_case, "Member banned."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_member_moderation(_actor, _subject, _params), do: {:error, :invalid_action}

  def emoji_entries_for_picker(current_user) do
    Chat.list_available_emojis(current_user)
    |> Enum.map(fn emoji ->
      %{
        id: emoji.id,
        name: emoji.name,
        shortcode: emoji.shortcode,
        url: Chat.asset_url(emoji.asset)
      }
    end)
  end

  def assign_channel_form_mode(socket, mode) when is_binary(mode) do
    assign_channel_form_mode(socket, String.to_existing_atom(mode))
  rescue
    ArgumentError -> assign_channel_form_mode(socket, :create_text)
  end

  def assign_channel_form_mode(socket, :create_category) do
    socket
    |> assign(:channel_form_mode, :create_category)
    |> assign(:channel_form_title, "Create category")
    |> assign(:editing_channel_id, nil)
  end

  def assign_channel_form_mode(socket, :edit_category) do
    socket
    |> assign(:channel_form_mode, :edit_category)
    |> assign(:channel_form_title, "Edit category")
  end

  def assign_channel_form_mode(socket, :edit_text) do
    socket
    |> assign(:channel_form_mode, :edit_text)
    |> assign(:channel_form_title, "Edit channel")
  end

  def assign_channel_form_mode(socket, _mode) do
    socket
    |> assign(:channel_form_mode, :create_text)
    |> assign(:channel_form_title, "Create text channel")
    |> assign(:editing_channel_id, nil)
  end

  def default_channel_attrs(:create_category) do
    %{kind: :category, name: "", slug: "", topic: nil, parent_channel_id: nil, nsfw: false}
  end

  def default_channel_attrs(_mode) do
    %{kind: :text, name: "", slug: "", topic: nil, parent_channel_id: nil, nsfw: false}
  end

  def edit_mode_for(channel) do
    if channel.kind == :category, do: :edit_category, else: :edit_text
  end

  def normalize_channel_params(channel_params, channel_form_mode) do
    kind =
      if channel_form_mode in [:create_category, :edit_category], do: "category", else: "text"

    channel_params
    |> Map.put("kind", kind)
    |> Map.update("parent_channel_id", nil, fn parent_id ->
      if kind == "category", do: nil, else: blank_to_nil(parent_id)
    end)
    |> Map.update("topic", nil, &blank_to_nil/1)
    |> Map.update("slug", "", fn slug ->
      slug = String.trim(slug || "")
      if slug == "", do: slugify(Map.get(channel_params, "name", "")), else: slug
    end)
  end

  def creation_flash(channel) do
    if channel.kind == :category, do: "Category created.", else: "Channel created."
  end

  def next_channel_position do
    Chat.list_channels()
    |> Enum.map(& &1.position)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  def assign_channel_form(socket, channel \\ nil) do
    channel = channel || %Chat.Channel{}

    attrs =
      if channel.id do
        %{
          name: channel.name,
          slug: channel.slug,
          topic: channel.topic,
          kind: channel.kind,
          parent_channel_id: channel.parent_channel_id,
          nsfw: channel.nsfw
        }
      else
        default_channel_attrs(socket.assigns.channel_form_mode)
      end

    form =
      channel
      |> Chat.change_channel(attrs)
      |> to_form(as: :channel)

    socket
    |> assign(:channel_form, form)
    |> assign(:editing_channel_id, channel.id)
  end

  defp swap_in_sections(sections, channel_id, direction) do
    Enum.reduce_while(Enum.with_index(sections), :error, fn {section, section_index}, _acc ->
      ids = Enum.map(section.channels, & &1.id)

      case Enum.find_index(ids, &(&1 == channel_id)) do
        nil ->
          {:cont, :error}

        index ->
          target_index = if direction == "up", do: index - 1, else: index + 1

          if target_index < 0 or target_index >= length(ids) do
            {:halt, :error}
          else
            updated_ids = swap_positions(ids, index, target_index)

            updated_sections =
              List.update_at(sections, section_index, fn current_section ->
                %{current_section | channels: updated_ids}
              end)

            {:halt, {:ok, serialize_sections(updated_sections)}}
          end
      end
    end)
  end

  defp serialize_sections(sections) do
    Enum.map(sections, fn section ->
      %{
        category: section.category && section.category.id,
        channels:
          Enum.map(section.channels, fn channel ->
            if is_binary(channel), do: channel, else: channel.id
          end)
      }
    end)
  end

  defp swap_positions(list, left, right) do
    left_value = Enum.at(list, left)
    right_value = Enum.at(list, right)

    list
    |> List.replace_at(left, right_value)
    |> List.replace_at(right, left_value)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
