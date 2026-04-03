defmodule RfchatWeb.SettingsLive.State do
  @moduledoc false

  import Ecto.Query, warn: false
  import Phoenix.Component, only: [assign: 3, to_form: 2]

  alias Rfchat.Accounts
  alias Rfchat.Bots
  alias Rfchat.Chat
  alias Rfchat.Chat.ChannelMembership
  alias Rfchat.Chat.ServerSettings
  alias Rfchat.Chat.UserNotificationSetting
  alias Rfchat.Repo
  alias RfchatWeb.Live.SharedHelpers

  def init(socket) do
    current_user = socket.assigns.current_user
    channels = Chat.list_channels_for_user(current_user)
    :ok = Chat.ensure_channel_memberships_for_user(current_user, channels)

    can_manage_channels? = SharedHelpers.can_manage_channels?(socket.assigns.current_scope)
    can_manage_emojis? = SharedHelpers.can_manage_emojis?(socket.assigns.current_scope)
    can_moderate_members? = SharedHelpers.can_moderate_members?(socket.assigns.current_scope)
    can_manage_bots? = Bots.can_manage_bots?(socket.assigns.current_scope)
    server_settings = Chat.get_server_settings()

    socket
    |> assign(:current_user, current_user)
    |> assign(:server_settings, server_settings)
    |> assign(:current_server, server_settings)
    |> assign(:page_title, server_settings.name)
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
    |> assign(:server_settings_form, server_settings_form(server_settings))
    |> assign_notification_form()
    |> SharedHelpers.assign_channel_form()
    |> assign(:emoji_form, to_form(Chat.change_emoji(%Chat.Emoji{}, %{}), as: :emoji))
  end

  def assign_notification_form(socket) do
    form =
      socket.assigns.notification_setting
      |> UserNotificationSetting.changeset(%{})
      |> to_form(as: :notification)

    assign(socket, :notification_form, form)
  end

  def server_settings_form(%ServerSettings{} = server_settings) do
    server_settings
    |> Chat.change_server_settings(%{name: server_settings.name || Chat.default_server_name()})
    |> to_form(as: :server_settings)
  end

  def maybe_attach_server_icon_upload(socket, attrs) do
    case SharedHelpers.uploaded_entry(socket, :server_icon) do
      nil ->
        attrs

      _entry ->
        result =
          Phoenix.LiveView.consume_uploaded_entries(socket, :server_icon, fn %{path: path},
                                                                             entry ->
            {:ok,
             %{
               path: path,
               client_name: entry.client_name,
               client_type: entry.client_type
             }}
          end)

        case result do
          [upload] -> Map.put(attrs, "icon_upload", upload)
          _ -> attrs
        end
    end
  end

  def channel_memberships_map(current_user, channels) do
    channel_ids = Enum.map(channels, & &1.id)

    ChannelMembership
    |> where(
      [membership],
      membership.user_id == ^current_user.id and membership.channel_id in ^channel_ids
    )
    |> Repo.all()
    |> Map.new(&{&1.channel_id, &1})
  end

  def refresh_channels(socket) do
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

  def refresh_member_presence(socket) do
    assign(socket, :member_presence, Accounts.list_members_with_presence())
  end

  def save_channel(socket, channel_params) do
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
             |> Phoenix.LiveView.put_flash(:info, SharedHelpers.creation_flash(channel))}

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
             |> Phoenix.LiveView.put_flash(:info, "Channel updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :channel_form, to_form(changeset, as: :channel))}
        end
    end
  end

  def move_channel(channel_id, direction), do: SharedHelpers.move_channel(channel_id, direction)

  def save_emoji(socket, emoji_params) do
    SharedHelpers.save_emoji(socket, emoji_params, &refresh_custom_emojis/1)
  end

  def refresh_custom_emojis(socket) do
    current_user = socket.assigns.current_user
    assign(socket, :custom_emojis, SharedHelpers.emoji_entries_for_picker(current_user))
  end

  def run_member_moderation(actor, subject, params),
    do: SharedHelpers.run_member_moderation(actor, subject, params)

  def refresh_bot_assigns(socket) do
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

  def bot_form_defaults do
    %{"display_name" => "", "username" => "", "email" => "", "bio" => "", "role_ids" => []}
  end

  def manageable_roles do
    Chat.list_roles()
    |> Enum.reject(& &1.is_default)
  end

  def truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  def truthy?(_value), do: false

  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value
end
