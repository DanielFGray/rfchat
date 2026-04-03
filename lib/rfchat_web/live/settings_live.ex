defmodule RfchatWeb.SettingsLive do
  use RfchatWeb, :live_view

  import Ecto.Query, warn: false

  alias Rfchat.Accounts
  alias Rfchat.Bots
  alias Rfchat.Chat
  alias Rfchat.Chat.ChannelMembership
  alias Rfchat.Chat.UserNotificationSetting
  alias Rfchat.Repo
  alias RfchatWeb.Live.SharedHelpers

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels_for_user(current_user)
    :ok = Chat.ensure_channel_memberships_for_user(current_user, channels)

    can_manage_channels? = SharedHelpers.can_manage_channels?(socket.assigns.current_scope)
    can_manage_emojis? = SharedHelpers.can_manage_emojis?(socket.assigns.current_scope)
    can_moderate_members? = SharedHelpers.can_moderate_members?(socket.assigns.current_scope)
    can_manage_bots? = Bots.can_manage_bots?(socket.assigns.current_scope)

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
      |> assign(:can_manage_bots?, can_manage_bots?)
      |> assign(:notification_setting, Chat.get_user_notification_setting(current_user))
      |> assign(:channels, channels)
      |> assign(:channel_memberships, channel_memberships_map(current_user, channels))
      |> assign(:channel_sections, Chat.list_channel_tree_for_user(current_user))
      |> assign(
        :all_channel_sections,
        SharedHelpers.channel_sections_for_manager(can_manage_channels?)
      )
      |> assign(:custom_emojis, SharedHelpers.emoji_entries_for_picker(current_user))
      |> assign(:bot_users, if(can_manage_bots?, do: Bots.list_bot_users(), else: []))
      |> assign(:manageable_roles, if(can_manage_bots?, do: manageable_roles(), else: []))
      |> assign(:bot_form, to_form(bot_form_defaults(), as: :bot))
      |> assign(:bot_token_forms, %{})
      |> assign(:revealed_bot_tokens, %{})
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
      |> SharedHelpers.assign_channel_form()
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
  def handle_event("create_bot", %{"bot" => bot_params}, socket) do
    if socket.assigns.can_manage_bots? do
      role_ids = List.wrap(Map.get(bot_params, "role_ids", []))
      bot_params = Map.put(bot_params, "role_ids", Enum.reject(role_ids, &(&1 == "")))

      case Bots.create_bot(bot_params, socket.assigns.current_user) do
        {:ok, _bot} ->
          {:noreply,
           socket
           |> refresh_bot_assigns()
           |> assign(:bot_form, to_form(bot_form_defaults(), as: :bot))
           |> put_flash(:info, "Bot created.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :bot_form, to_form(changeset, as: :bot))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not create bot: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage bots.")}
    end
  end

  @impl true
  def handle_event("create_bot_token", %{"id" => bot_id, "token" => token_params}, socket) do
    if socket.assigns.can_manage_bots? do
      bot_user = Bots.get_bot_user!(bot_id)

      case Bots.create_bot_token(bot_user, token_params, socket.assigns.current_user) do
        {:ok, token_info} ->
          {:noreply,
           socket
           |> refresh_bot_assigns()
           |> assign(
             :revealed_bot_tokens,
             Map.put(socket.assigns.revealed_bot_tokens, bot_id, token_info.token)
           )
           |> put_flash(:info, "Bot token created. Copy it now; it will not be shown again.")}

        {:error, changeset} ->
          token_forms =
            Map.put(socket.assigns.bot_token_forms, bot_id, to_form(changeset, as: :token))

          {:noreply, assign(socket, :bot_token_forms, token_forms)}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage bots.")}
    end
  end

  @impl true
  def handle_event("revoke_bot_token", %{"id" => token_id}, socket) do
    if socket.assigns.can_manage_bots? do
      case Repo.get(Chat.BotToken, token_id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Bot token not found.")}

        token ->
          case Bots.revoke_bot_token(token, socket.assigns.current_user) do
            {:ok, _revoked} ->
              {:noreply,
               socket
               |> refresh_bot_assigns()
               |> put_flash(:info, "Bot token revoked.")}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, "Could not revoke bot token.")}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage bots.")}
    end
  end

  @impl true
  def handle_event("close_manage_emojis", _params, socket) do
    {:noreply, assign(socket, :manage_emojis_open?, false)}
  end

  @impl true
  def handle_event("new_channel_form", %{"mode" => mode}, socket) do
    if socket.assigns.can_manage_channels? do
      {:noreply,
       socket
       |> SharedHelpers.assign_channel_form_mode(mode)
       |> SharedHelpers.assign_channel_form()}
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
       |> SharedHelpers.assign_channel_form_mode(SharedHelpers.edit_mode_for(channel))
       |> SharedHelpers.assign_channel_form(channel)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("cancel_channel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_channel_id, nil)
     |> SharedHelpers.assign_channel_form_mode(:create_text)
     |> SharedHelpers.assign_channel_form()}
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
           |> SharedHelpers.assign_channel_form_mode(:create_text)
           |> SharedHelpers.assign_channel_form()
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

  defp refresh_channels(socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels_for_user(current_user)

    socket
    |> assign(:channels, channels)
    |> assign(:channel_sections, Chat.list_channel_tree_for_user(current_user))
    |> assign(
      :all_channel_sections,
      SharedHelpers.channel_sections_for_manager(socket.assigns.can_manage_channels?)
    )
    |> assign(:channel_memberships, channel_memberships_map(current_user, channels))
  end

  defp refresh_member_presence(socket) do
    assign(socket, :member_presence, Accounts.list_members_with_presence())
  end

  defp save_channel(socket, channel_params) do
    attrs =
      SharedHelpers.normalize_channel_params(channel_params, socket.assigns.channel_form_mode)

    case socket.assigns.editing_channel_id do
      nil ->
        attrs = Map.put_new(attrs, "position", SharedHelpers.next_channel_position())

        case Chat.create_channel(attrs) do
          {:ok, channel} ->
            {:noreply,
             socket
             |> refresh_channels()
             |> SharedHelpers.assign_channel_form_mode(
               if(channel.kind == :category, do: :create_category, else: :create_text)
             )
             |> SharedHelpers.assign_channel_form()
             |> put_flash(:info, SharedHelpers.creation_flash(channel))}

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
             |> SharedHelpers.assign_channel_form_mode(
               SharedHelpers.edit_mode_for(updated_channel)
             )
             |> SharedHelpers.assign_channel_form(updated_channel)
             |> put_flash(:info, "Channel updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :channel_form, to_form(changeset, as: :channel))}
        end
    end
  end

  defp move_channel(channel_id, direction), do: SharedHelpers.move_channel(channel_id, direction)

  defp save_emoji(socket, emoji_params) do
    SharedHelpers.save_emoji(socket, emoji_params, &refresh_custom_emojis/1)
  end

  defp refresh_custom_emojis(socket) do
    current_user = socket.assigns.current_user
    assign(socket, :custom_emojis, SharedHelpers.emoji_entries_for_picker(current_user))
  end

  defp run_member_moderation(actor, subject, params),
    do: SharedHelpers.run_member_moderation(actor, subject, params)

  defp mention_alerts_enabled?(setting) do
    setting.desktop_enabled && setting.notify_on_mentions
  end

  defp manageable_categories(sections) do
    sections
    |> Enum.map(& &1.category)
    |> Enum.reject(&is_nil/1)
  end

  defp section_dom_id(nil), do: "channel-section-uncategorized"
  defp section_dom_id(category), do: "channel-section-#{category.slug}"

  # ARCHITECTURE NOTE: Stage A cleanup can still extract shared presentation helpers
  # like section_label/member_status_class/member_status_label/scrollbar_classes
  # into a dedicated Live UI helper module once we want to reduce duplicate view glue further.
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

  defp emoji_upload_error(:too_large), do: "That file is too large."
  defp emoji_upload_error(:too_many_files), do: "Choose only one file."
  defp emoji_upload_error(:not_accepted), do: "That file type is not allowed."
  defp emoji_upload_error(_error), do: "Upload failed."

  defp refresh_bot_assigns(socket) do
    if socket.assigns.can_manage_bots? do
      bot_users = Bots.list_bot_users()

      bot_token_forms =
        Enum.reduce(bot_users, %{}, fn bot_user, acc ->
          Map.put_new(
            acc,
            bot_user.id,
            to_form(%{"label" => "", "expires_in_days" => ""}, as: :token)
          )
        end)

      socket
      |> assign(:bot_users, bot_users)
      |> assign(:manageable_roles, manageable_roles())
      |> assign(
        :bot_token_forms,
        Map.merge(bot_token_forms, socket.assigns.bot_token_forms || %{})
      )
    else
      socket
    end
  end

  defp bot_form_defaults do
    %{"display_name" => "", "username" => "", "email" => "", "bio" => "", "role_ids" => []}
  end

  defp manageable_roles do
    Chat.list_roles()
    |> Enum.reject(& &1.is_default)
  end

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
end
