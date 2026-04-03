defmodule RfchatWeb.SettingsLive do
  use RfchatWeb, :live_view

  import Ecto.Query, warn: false

  alias Rfchat.Accounts
  alias Rfchat.Bots
  alias Rfchat.Chat
  alias Rfchat.Repo
  alias RfchatWeb.Live.SharedHelpers
  alias RfchatWeb.SettingsLive.State

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> allow_upload(:server_icon,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 1_000_000
      )
      |> allow_upload(:emoji_image,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 1,
        max_file_size: 512_000
      )
      |> State.init()

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
         |> State.assign_notification_form()
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
         |> State.assign_notification_form()
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
        {:noreply,
         socket |> assign(:notification_setting, setting) |> State.assign_notification_form()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not disable mention alerts.")}
    end
  end

  @impl true
  def handle_event("save_channel_notification", %{"channel_notification" => attrs}, socket) do
    channel_id = Map.get(attrs, "channel_id")

    membership_attrs = %{
      notification_level: State.blank_to_nil(Map.get(attrs, "notification_level")) || :default,
      is_favorite: State.truthy?(Map.get(attrs, "is_favorite"))
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
           State.channel_memberships_map(socket.assigns.current_user, channels)
         )
         |> put_flash(:info, "Channel preference saved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update that channel preference.")}
    end
  end

  @impl true
  def handle_event("remove_server_icon", _params, socket) do
    settings = socket.assigns.server_settings || Chat.get_server_settings()

    case Chat.update_server_settings(
           %{"name" => settings.name, "icon_asset_id" => ""},
           socket.assigns.current_user
         ) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:server_settings, settings)
         |> assign(:current_server, settings)
         |> assign(:page_title, settings.name)
         |> assign(:server_settings_form, State.server_settings_form(settings))
         |> put_flash(:info, "Server icon removed.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove the server icon.")}
    end
  end

  @impl true
  def handle_event("save_server_settings", %{"server_settings" => attrs}, socket) do
    attrs = State.maybe_attach_server_icon_upload(socket, attrs)

    case Chat.update_server_settings(attrs, socket.assigns.current_user) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:server_settings, settings)
         |> assign(:current_server, settings)
         |> assign(:page_title, settings.name)
         |> assign(:server_settings_form, State.server_settings_form(settings))
         |> put_flash(:info, "Server settings updated.")}

      {:error, :invalid_upload_type} ->
        {:noreply, put_flash(socket, :error, "Server icon must be png, jpg, gif, or webp.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :server_settings_form, to_form(changeset, as: :server_settings))}
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
           |> State.refresh_bot_assigns()
           |> assign(:bot_form, to_form(State.bot_form_defaults(), as: :bot))
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
           |> State.refresh_bot_assigns()
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
               |> State.refresh_bot_assigns()
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
      State.save_channel(socket, channel_params)
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
           |> State.refresh_channels()
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
      case State.move_channel(channel_id, direction) do
        :ok -> {:noreply, State.refresh_channels(socket)}
        :error -> {:noreply, put_flash(socket, :error, "Could not reorder that channel.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels.")}
    end
  end

  @impl true
  def handle_event("save_emoji", %{"emoji" => emoji_params}, socket) do
    if socket.assigns.can_manage_emojis? do
      State.save_emoji(socket, emoji_params)
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
           |> State.refresh_custom_emojis()
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
  def handle_event("promote_to_owner", %{"id" => user_id}, socket) do
    actor = socket.assigns.current_user
    subject = Accounts.get_user_with_membership!(user_id)

    case Accounts.promote_to_owner(actor, subject) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> State.refresh_member_presence()
         |> put_flash(:info, "#{subject.display_name} is now an owner.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners can promote other users.")}

      {:error, :self} ->
        {:noreply, put_flash(socket, :error, "You cannot promote yourself.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not promote that user.")}
    end
  end

  @impl true
  def handle_event("demote_from_owner", %{"id" => user_id}, socket) do
    actor = socket.assigns.current_user
    subject = Accounts.get_user_with_membership!(user_id)

    case Accounts.demote_from_owner(actor, subject) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> State.refresh_member_presence()
         |> put_flash(:info, "#{subject.display_name} is no longer an owner.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners can demote other owners.")}

      {:error, :self} ->
        {:noreply, put_flash(socket, :error, "You cannot demote yourself.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not demote that user.")}
    end
  end

  @impl true
  def handle_event("moderate_member", %{"user_id" => user_id, "moderation" => params}, socket) do
    if socket.assigns.can_moderate_members? do
      actor = socket.assigns.current_user
      subject = Accounts.get_user_with_membership!(user_id)

      case State.run_member_moderation(actor, subject, params) do
        {:ok, _subject, _case, message} ->
          {:noreply,
           socket
           |> State.refresh_member_presence()
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
end
