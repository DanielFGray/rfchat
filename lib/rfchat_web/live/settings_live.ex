defmodule RfchatWeb.SettingsLive do
  use RfchatWeb, :live_view

  import Ecto.Query, warn: false

  alias Rfchat.Accounts
  alias Rfchat.Chat
  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.ChannelMembership
  alias Rfchat.Chat.UserNotificationSetting
  alias Rfchat.Repo

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels_for_user(current_user)
    :ok = Chat.ensure_channel_memberships_for_user(current_user, channels)

    can_manage_channels? = can_manage_channels?(socket.assigns.current_scope)
    can_manage_emojis? = can_manage_emojis?(socket.assigns.current_scope)
    can_moderate_members? = can_moderate_members?(socket.assigns.current_scope)

    socket =
      socket
      |> allow_upload(:emoji_image,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 512_000
      )
      |> assign(:current_user, current_user)
      |> assign(:active_tab, "profile")
      |> assign(:can_manage_channels?, can_manage_channels?)
      |> assign(:can_manage_emojis?, can_manage_emojis?)
      |> assign(:can_moderate_members?, can_moderate_members?)
      |> assign(:notification_setting, Chat.get_user_notification_setting(current_user))
      |> assign(:channels, channels)
      |> assign(:channel_memberships, channel_memberships_map(current_user, channels))
      |> assign(:channel_sections, Chat.list_channel_tree_for_user(current_user))
      |> assign(:all_channel_sections, channel_sections_for_manager(can_manage_channels?))
      |> assign(:custom_emojis, emoji_entries_for_picker(current_user))
      |> assign(:manage_channels_open?, false)
      |> assign(:manage_emojis_open?, false)
      |> assign(:member_presence, Accounts.list_members_with_presence())
      |> assign(:member_action_user_id, nil)
      |> assign(:member_action_form, to_form(Chat.change_moderation_action(%{}), as: :moderation))
      |> assign(:moderation_cases, [])
      |> assign(:channel_form_mode, :create_text)
      |> assign(:channel_form_title, "Create text channel")
      |> assign(:editing_channel_id, nil)
      |> assign(:profile_form, to_form(Accounts.change_profile_user(current_user), as: :user))
      |> assign_notification_form()
      |> assign_channel_form()
      |> assign(:emoji_form, to_form(Chat.change_emoji(%Chat.Emoji{}, %{}), as: :emoji))

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket)
      when tab in ["profile", "notifications", "channel_notifications", "theme", "server"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket)
      when tab in ["profile", "notifications", "channel_notifications", "theme", "server"] do
    {:noreply, push_patch(socket, to: ~p"/settings?tab=#{tab}")}
  end

  @impl true
  def handle_event("save_profile", %{"user" => user_params}, socket) do
    case Accounts.update_profile_user(socket.assigns.current_user, user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:profile_form, to_form(Accounts.change_profile_user(user), as: :user))
         |> put_flash(:info, "Profile updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: :user))}
    end
  end

  @impl true
  def handle_event("save_notifications", %{"notification" => attrs}, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_user, attrs) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:notification_setting, setting)
         |> assign_notification_form()
         |> put_flash(:info, "Notification preferences updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :notification_form, to_form(changeset, as: :notification))}
    end
  end

  @impl true
  def handle_event("enable_desktop_mentions", _params, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_user, %{
           desktop_enabled: true,
           notify_on_mentions: true
         }) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:notification_setting, setting)
         |> assign_notification_form()
         |> push_event("notifications:request-permission", %{})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not enable mention alerts.")}
    end
  end

  @impl true
  def handle_event("disable_desktop_mentions", _params, socket) do
    case Chat.update_user_notification_setting(socket.assigns.current_user, %{
           desktop_enabled: false
         }) do
      {:ok, setting} ->
        {:noreply, socket |> assign(:notification_setting, setting) |> assign_notification_form()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not disable mention alerts.")}
    end
  end

  @impl true
  def handle_event("save_channel_notification", %{"channel_notification" => attrs}, socket) do
    channel_id = Map.get(attrs, "channel_id")

    membership_attrs = %{
      notification_level: blank_to_nil(Map.get(attrs, "notification_level")) || :default,
      is_favorite: truthy?(Map.get(attrs, "is_favorite"))
    }

    case Chat.update_channel_membership_notification(
           socket.assigns.current_user,
           channel_id,
           membership_attrs
         ) do
      {:ok, _membership} ->
        channels = Chat.list_channels_for_user(socket.assigns.current_user)

        {:noreply,
         socket
         |> assign(:channels, channels)
         |> assign(
           :channel_memberships,
           channel_memberships_map(socket.assigns.current_user, channels)
         )
         |> put_flash(:info, "Channel preference saved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update that channel preference.")}
    end
  end

  @impl true
  def handle_event("toggle_manage_channels", _params, socket) do
    if socket.assigns.can_manage_channels? do
      {:noreply, assign(socket, :manage_channels_open?, !socket.assigns.manage_channels_open?)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("close_manage_channels", _params, socket) do
    {:noreply, assign(socket, :manage_channels_open?, false)}
  end

  @impl true
  def handle_event("toggle_manage_emojis", _params, socket) do
    if socket.assigns.can_manage_emojis? do
      {:noreply, assign(socket, :manage_emojis_open?, !socket.assigns.manage_emojis_open?)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage emojis.")}
    end
  end

  @impl true
  def handle_event("close_manage_emojis", _params, socket) do
    {:noreply, assign(socket, :manage_emojis_open?, false)}
  end

  @impl true
  def handle_event("new_channel_form", %{"mode" => mode}, socket) do
    if socket.assigns.can_manage_channels? do
      {:noreply, socket |> assign_channel_form_mode(mode) |> assign_channel_form()}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("edit_channel", %{"id" => channel_id}, socket) do
    if socket.assigns.can_manage_channels? do
      channel = Chat.get_channel!(channel_id)

      {:noreply,
       socket
       |> assign(:manage_channels_open?, true)
       |> assign(:editing_channel_id, channel.id)
       |> assign_channel_form_mode(edit_mode_for(channel))
       |> assign_channel_form(channel)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("cancel_channel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_channel_id, nil)
     |> assign_channel_form_mode(:create_text)
     |> assign_channel_form()}
  end

  @impl true
  def handle_event("save_channel", %{"channel" => channel_params}, socket) do
    if socket.assigns.can_manage_channels? do
      save_channel(socket, channel_params)
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("delete_channel", %{"id" => channel_id}, socket) do
    if socket.assigns.can_manage_channels? do
      channel = Chat.get_channel!(channel_id)

      case Chat.delete_channel(channel) do
        {:ok, _channel} ->
          {:noreply,
           socket
           |> refresh_channels()
           |> assign(:editing_channel_id, nil)
           |> assign_channel_form_mode(:create_text)
           |> assign_channel_form()
           |> put_flash(:info, "Channel deleted.")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not delete that channel.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("move_channel", %{"id" => channel_id, "direction" => direction}, socket) do
    if socket.assigns.can_manage_channels? do
      case move_channel(channel_id, direction) do
        :ok -> {:noreply, refresh_channels(socket)}
        :error -> {:noreply, put_flash(socket, :error, "Could not reorder that channel.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("save_emoji", %{"emoji" => emoji_params}, socket) do
    if socket.assigns.can_manage_emojis? do
      save_emoji(socket, emoji_params)
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage emojis.")}
    end
  end

  @impl true
  def handle_event("delete_emoji", %{"id" => emoji_id}, socket) do
    if socket.assigns.can_manage_emojis? do
      emoji = Chat.get_emoji!(emoji_id)

      case Chat.delete_custom_emoji(emoji) do
        {:ok, _emoji} ->
          {:noreply,
           socket
           |> refresh_custom_emojis()
           |> put_flash(:info, "Emoji deleted.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not delete that emoji.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage emojis.")}
    end
  end

  @impl true
  def handle_event("toggle_member_actions", %{"id" => user_id}, socket) do
    if socket.assigns.can_moderate_members? do
      next_user_id = if socket.assigns.member_action_user_id == user_id, do: nil, else: user_id

      moderation_cases =
        if next_user_id, do: Chat.list_moderation_cases_for_user(user_id), else: []

      {:noreply,
       socket
       |> assign(:member_action_user_id, next_user_id)
       |> assign(:moderation_cases, moderation_cases)
       |> assign(
         :member_action_form,
         to_form(Chat.change_moderation_action(%{}), as: :moderation)
       )}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to moderate members.")}
    end
  end

  @impl true
  def handle_event("close_member_actions", _params, socket) do
    {:noreply,
     socket
     |> assign(:member_action_user_id, nil)
     |> assign(:moderation_cases, [])
     |> assign(:member_action_form, to_form(Chat.change_moderation_action(%{}), as: :moderation))}
  end

  @impl true
  def handle_event("moderate_member", %{"user_id" => user_id, "moderation" => params}, socket) do
    if socket.assigns.can_moderate_members? do
      actor = socket.assigns.current_user
      subject = Accounts.get_user_with_membership!(user_id)

      case run_member_moderation(actor, subject, params) do
        {:ok, _subject, _case, message} ->
          {:noreply,
           socket
           |> refresh_member_presence()
           |> assign(:moderation_cases, Chat.list_moderation_cases_for_user(user_id))
           |> assign(
             :member_action_form,
             to_form(Chat.change_moderation_action(%{}), as: :moderation)
           )
           |> put_flash(:info, message)}

        {:error, :forbidden} ->
          {:noreply,
           put_flash(socket, :error, "You do not have permission to moderate that member.")}

        {:error, :invalid_duration} ->
          changeset =
            Chat.change_moderation_action(params)
            |> Ecto.Changeset.add_error(:duration_minutes, "must be greater than zero")

          {:noreply, assign(socket, :member_action_form, to_form(changeset, as: :moderation))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not complete that moderation action.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to moderate members.")}
    end
  end

  defp assign_notification_form(socket) do
    form =
      socket.assigns.notification_setting
      |> UserNotificationSetting.changeset(%{})
      |> to_form(as: :notification)

    assign(socket, :notification_form, form)
  end

  defp channel_memberships_map(current_user, channels) do
    channel_ids = Enum.map(channels, & &1.id)

    ChannelMembership
    |> where(
      [membership],
      membership.user_id == ^current_user.id and membership.channel_id in ^channel_ids
    )
    |> Repo.all()
    |> Map.new(&{&1.channel_id, &1})
  end

  defp assign_channel_form(socket, channel \\ nil) do
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

  defp refresh_channels(socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels_for_user(current_user)

    socket
    |> assign(:channels, channels)
    |> assign(:channel_sections, Chat.list_channel_tree_for_user(current_user))
    |> assign(
      :all_channel_sections,
      channel_sections_for_manager(socket.assigns.can_manage_channels?)
    )
    |> assign(:channel_memberships, channel_memberships_map(current_user, channels))
  end

  defp refresh_member_presence(socket) do
    assign(socket, :member_presence, Accounts.list_members_with_presence())
  end

  defp save_channel(socket, channel_params) do
    attrs = normalize_channel_params(channel_params, socket)

    case socket.assigns.editing_channel_id do
      nil ->
        attrs = Map.put_new(attrs, "position", next_channel_position())

        case Chat.create_channel(attrs) do
          {:ok, channel} ->
            {:noreply,
             socket
             |> refresh_channels()
             |> assign_channel_form_mode(
               if(channel.kind == :category, do: :create_category, else: :create_text)
             )
             |> assign_channel_form()
             |> put_flash(:info, creation_flash(channel))}

          {:error, changeset} ->
            {:noreply, assign(socket, :channel_form, to_form(changeset, as: :channel))}
        end

      channel_id ->
        channel = Chat.get_channel!(channel_id)

        case Chat.update_channel(channel, attrs) do
          {:ok, updated_channel} ->
            {:noreply,
             socket
             |> refresh_channels()
             |> assign(:editing_channel_id, updated_channel.id)
             |> assign_channel_form_mode(edit_mode_for(updated_channel))
             |> assign_channel_form(updated_channel)
             |> put_flash(:info, "Channel updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :channel_form, to_form(changeset, as: :channel))}
        end
    end
  end

  defp assign_channel_form_mode(socket, mode) when is_binary(mode) do
    assign_channel_form_mode(socket, String.to_existing_atom(mode))
  rescue
    ArgumentError -> assign_channel_form_mode(socket, :create_text)
  end

  defp assign_channel_form_mode(socket, :create_category) do
    socket
    |> assign(:channel_form_mode, :create_category)
    |> assign(:channel_form_title, "Create category")
    |> assign(:editing_channel_id, nil)
  end

  defp assign_channel_form_mode(socket, :edit_category) do
    socket
    |> assign(:channel_form_mode, :edit_category)
    |> assign(:channel_form_title, "Edit category")
  end

  defp assign_channel_form_mode(socket, :edit_text) do
    socket
    |> assign(:channel_form_mode, :edit_text)
    |> assign(:channel_form_title, "Edit channel")
  end

  defp assign_channel_form_mode(socket, _mode) do
    socket
    |> assign(:channel_form_mode, :create_text)
    |> assign(:channel_form_title, "Create text channel")
    |> assign(:editing_channel_id, nil)
  end

  defp default_channel_attrs(:create_category) do
    %{kind: :category, name: "", slug: "", topic: nil, parent_channel_id: nil, nsfw: false}
  end

  defp default_channel_attrs(_mode) do
    %{kind: :text, name: "", slug: "", topic: nil, parent_channel_id: nil, nsfw: false}
  end

  defp edit_mode_for(channel) do
    if channel.kind == :category, do: :edit_category, else: :edit_text
  end

  defp normalize_channel_params(channel_params, socket) do
    mode = socket.assigns.channel_form_mode
    kind = if mode in [:create_category, :edit_category], do: "category", else: "text"

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

  defp creation_flash(channel) do
    if channel.kind == :category, do: "Category created.", else: "Channel created."
  end

  defp next_channel_position do
    Chat.list_channels()
    |> Enum.map(& &1.position)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  defp move_channel(channel_id, direction) do
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

  defp save_emoji(socket, emoji_params) do
    upload = uploaded_entry(socket, :emoji_image)

    if is_nil(upload) do
      {:noreply, put_flash(socket, :error, "Choose an image before saving the emoji.")}
    else
      case consume_emoji_upload(socket, upload, emoji_params) do
        {:ok, _emoji, socket} ->
          {:noreply,
           socket
           |> refresh_custom_emojis()
           |> assign(:emoji_form, to_form(Chat.change_emoji(%Chat.Emoji{}, %{}), as: :emoji))
           |> put_flash(:info, "Emoji added.")}

        {:error, :invalid_upload_type, socket} ->
          {:noreply, put_flash(socket, :error, "Emoji uploads must be png, jpg, gif, or webp.")}

        {:error, changeset, socket} ->
          {:noreply, assign(socket, :emoji_form, to_form(changeset, as: :emoji))}
      end
    end
  end

  defp consume_emoji_upload(socket, _upload, emoji_params) do
    result =
      consume_uploaded_entries(socket, :emoji_image, fn %{path: path}, entry ->
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

  defp uploaded_entry(socket, name) do
    socket.assigns.uploads[name].entries |> List.first()
  end

  defp refresh_custom_emojis(socket) do
    current_user = socket.assigns.current_user
    assign(socket, :custom_emojis, emoji_entries_for_picker(current_user))
  end

  defp run_member_moderation(actor, subject, %{
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

  defp run_member_moderation(actor, subject, %{"action" => "kick", "reason" => reason}) do
    case Chat.kick_member(actor, subject, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        {:ok, updated_subject, moderation_case, "Member kicked."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_member_moderation(actor, subject, %{"action" => "ban", "reason" => reason}) do
    case Chat.ban_member(actor, subject, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        {:ok, updated_subject, moderation_case, "Member banned."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_member_moderation(_actor, _subject, _params), do: {:error, :invalid_action}

  defp mention_alerts_enabled?(setting) do
    setting.desktop_enabled && setting.notify_on_mentions
  end

  defp can_manage_channels?(scope) do
    if is_nil(scope) do
      false
    else
      permissions = scope_permissions(scope)

      Authorization.has_permission?(permissions, :manage_channels) or
        Authorization.has_permission?(permissions, :administrator)
    end
  end

  defp can_manage_emojis?(scope) do
    if is_nil(scope) do
      false
    else
      permissions = scope_permissions(scope)

      Authorization.has_permission?(permissions, :manage_emojis_and_stickers) or
        Authorization.has_permission?(permissions, :administrator)
    end
  end

  defp can_moderate_members?(scope) do
    if is_nil(scope) do
      false
    else
      permissions = scope_permissions(scope)

      Authorization.has_permission?(permissions, :moderate_members) or
        Authorization.has_permission?(permissions, :kick_members) or
        Authorization.has_permission?(permissions, :ban_members) or
        Authorization.has_permission?(permissions, :administrator)
    end
  end

  defp scope_permissions(%{
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

  defp channel_sections_for_manager(true), do: Chat.list_channel_tree()
  defp channel_sections_for_manager(false), do: []

  defp manageable_categories(sections) do
    sections
    |> Enum.map(& &1.category)
    |> Enum.reject(&is_nil/1)
  end

  defp section_dom_id(nil), do: "channel-section-uncategorized"
  defp section_dom_id(category), do: "channel-section-#{category.slug}"

  defp section_label(nil), do: "Text channels"
  defp section_label(category), do: category.name

  defp channel_kind_badge(:forum), do: "forum"
  defp channel_kind_badge(:announcement), do: "news"
  defp channel_kind_badge(:voice), do: "voice"
  defp channel_kind_badge(:stage), do: "stage"
  defp channel_kind_badge(_kind), do: "text"

  defp member_status_class(:online), do: "bg-emerald-400"
  defp member_status_class(:recent), do: "bg-amber-400"
  defp member_status_class(:offline), do: "bg-zinc-600"

  defp member_status_label(:online), do: "online"
  defp member_status_label(:recent), do: "recent"
  defp member_status_label(:offline), do: "offline"

  defp selected_member(entry, member_action_user_id), do: entry.user.id == member_action_user_id

  defp member_action_available?(current_user, entry, permission_name) do
    current_user.id != entry.user.id and
      not entry.user.membership.is_owner and
      Chat.moderation_permission?(current_user, permission_name)
  end

  defp moderation_case_label(:timeout), do: "Timeout"
  defp moderation_case_label(:kick), do: "Kick"
  defp moderation_case_label(:ban), do: "Ban"

  defp moderation_case_label(other),
    do: other |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp member_timeout_label(entry) do
    timeout_until = entry.user.membership.timeout_until

    if timeout_until && DateTime.compare(timeout_until, DateTime.utc_now()) == :gt do
      Calendar.strftime(timeout_until, "%b %-d · %H:%M")
    end
  end

  defp emoji_entries_for_picker(current_user) do
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

  defp emoji_upload_error(:too_large), do: "That file is too large."
  defp emoji_upload_error(:too_many_files), do: "Choose only one file."
  defp emoji_upload_error(:not_accepted), do: "That file type is not allowed."
  defp emoji_upload_error(_error), do: "Upload failed."

  defp tab_active?(active_tab, tab), do: active_tab == tab

  defp notification_level_value(nil), do: "default"

  defp notification_level_value(membership),
    do: to_string(membership.notification_level || :default)

  defp scrollbar_classes do
    [
      "[scrollbar-width:thin]",
      "[scrollbar-color:rgba(255,255,255,0.12)_transparent]",
      "[&::-webkit-scrollbar]:h-2.5",
      "[&::-webkit-scrollbar]:w-2.5",
      "[&::-webkit-scrollbar-track]:bg-transparent",
      "[&::-webkit-scrollbar-thumb]:rounded-full",
      "[&::-webkit-scrollbar-thumb]:border-2",
      "[&::-webkit-scrollbar-thumb]:border-transparent",
      "[&::-webkit-scrollbar-thumb]:bg-[rgba(255,255,255,0.12)]",
      "[&::-webkit-scrollbar-thumb]:bg-clip-padding",
      "[&::-webkit-scrollbar-thumb:hover]:bg-[rgba(255,255,255,0.2)]"
    ]
    |> Enum.join(" ")
  end

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_value), do: false

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
