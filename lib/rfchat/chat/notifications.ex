defmodule Rfchat.Chat.Notifications do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.ChannelMembership
  alias Rfchat.Chat.ChannelNotificationOverride
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.MessageRoleMention
  alias Rfchat.Chat.MessageUserMention
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User
  alias Rfchat.Chat.UserNotificationSetting
  alias Rfchat.Repo

  def get_user_notification_setting(%User{} = user) do
    Repo.get_by(UserNotificationSetting, user_id: user.id) ||
      %UserNotificationSetting{user_id: user.id}
  end

  def update_user_notification_setting(%User{} = user, attrs) do
    user
    |> get_user_notification_setting()
    |> UserNotificationSetting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def update_channel_membership_notification(%User{} = user, channel_id, attrs) do
    membership =
      Repo.get_by(ChannelMembership, user_id: user.id, channel_id: channel_id) ||
        %ChannelMembership{
          user_id: user.id,
          channel_id: channel_id,
          joined_at: DateTime.utc_now()
        }

    membership
    |> ChannelMembership.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def unread_counts_for_user(%User{} = user, channels) when is_list(channels) do
    channel_ids = Enum.map(channels, & &1.id)
    counts = unread_counts_by_channel(user.id, channel_ids)

    Enum.into(channels, %{}, fn channel ->
      {channel.id, Map.get(counts, channel.id, 0)}
    end)
  end

  def unread_mentions_for_user(%User{} = user, channels) when is_list(channels) do
    channel_ids = Enum.map(channels, & &1.id)

    role_ids =
      Role
      |> join(:inner, [role], member_role in assoc(role, :member_roles))
      |> where([_role, member_role], member_role.user_id == ^user.id)
      |> select([role, _member_role], role.id)
      |> Repo.all()

    mentions = unread_mentions_by_channel(user.id, role_ids, channel_ids)

    Enum.into(channels, %{}, fn channel ->
      {channel.id, Map.get(mentions, channel.id, 0)}
    end)
  end

  def message_mentions_user?(message_id, %User{} = user) do
    role_ids =
      Role
      |> join(:inner, [role], member_role in assoc(role, :member_roles))
      |> where([_role, member_role], member_role.user_id == ^user.id)
      |> select([role, _member_role], role.id)
      |> Repo.all()

    direct_mention? =
      Repo.exists?(
        from(mention in MessageUserMention,
          where: mention.message_id == ^message_id and mention.mentioned_user_id == ^user.id
        )
      )

    role_mention? =
      role_ids != [] and
        Repo.exists?(
          from(mention in MessageRoleMention,
            where: mention.message_id == ^message_id and mention.mentioned_role_id in ^role_ids
          )
        )

    direct_mention? or role_mention?
  end

  def mention_notifications_enabled?(%User{} = user, %Channel{} = channel) do
    setting = get_user_notification_setting(user)

    cond do
      not setting.desktop_enabled ->
        false

      not setting.notify_on_mentions ->
        false

      true ->
        case effective_channel_notification_level(user, channel) do
          :nothing -> false
          _ -> true
        end
    end
  end

  def mark_channel_read(%User{} = user, %Channel{} = channel, message \\ nil) do
    message = message || latest_message_for_channel(channel.id)
    now = DateTime.utc_now()
    last_read_at = message && DateTime.add(message.inserted_at, 1, :microsecond)

    %ChannelMembership{}
    |> ChannelMembership.changeset(%{
      channel_id: channel.id,
      user_id: user.id,
      joined_at: now,
      last_read_message_id: message && message.id,
      last_read_at: last_read_at
    })
    |> Repo.insert!(
      on_conflict: [
        set: [
          last_read_message_id: message && message.id,
          last_read_at: last_read_at,
          updated_at: now
        ]
      ],
      conflict_target: [:channel_id, :user_id]
    )

    :ok
  end

  defp latest_message_for_channel(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id and is_nil(message.deleted_at))
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(1)
    |> Repo.one()
  end

  defp unread_counts_by_channel(_user_id, []), do: %{}

  defp unread_counts_by_channel(user_id, channel_ids) do
    channel_ids
    |> unread_messages_query(user_id)
    |> group_by([message], message.channel_id)
    |> select([message], {message.channel_id, count(message.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp unread_mentions_by_channel(_user_id, _role_ids, []), do: %{}

  defp unread_mentions_by_channel(user_id, role_ids, channel_ids) do
    direct_mentions_query =
      channel_ids
      |> unread_messages_query(user_id)
      |> join(:inner, [message, _membership, _last_read_message], mention in MessageUserMention,
        on: mention.message_id == message.id and mention.mentioned_user_id == ^user_id
      )
      |> select([message, _membership, _last_read_message, _mention], {
        message.channel_id,
        message.id
      })

    role_mentions_query =
      if role_ids == [] do
        nil
      else
        channel_ids
        |> unread_messages_query(user_id)
        |> join(:inner, [message, _membership, _last_read_message], mention in MessageRoleMention,
          on: mention.message_id == message.id and mention.mentioned_role_id in ^role_ids
        )
        |> select([message, _membership, _last_read_message, _mention], {
          message.channel_id,
          message.id
        })
      end

    [direct_mentions_query, role_mentions_query]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&Repo.all/1)
    |> Enum.group_by(fn {channel_id, _message_id} -> channel_id end, fn {_channel_id, message_id} ->
      message_id
    end)
    |> Map.new(fn {channel_id, message_ids} ->
      {channel_id, message_ids |> MapSet.new() |> MapSet.size()}
    end)
  end

  defp unread_messages_query(channel_ids, user_id) do
    boundary = unread_boundary_dynamic()

    from(message in Message,
      left_join: membership in ChannelMembership,
      on: membership.user_id == ^user_id and membership.channel_id == message.channel_id,
      left_join: last_read_message in Message,
      on: last_read_message.id == membership.last_read_message_id,
      where: message.channel_id in ^channel_ids,
      where: is_nil(message.deleted_at),
      where: message.author_id != ^user_id,
      where: ^boundary
    )
  end

  defp unread_boundary_dynamic do
    dynamic(
      [message, membership, last_read_message],
      is_nil(membership.id) or
        (not is_nil(membership.last_read_message_id) and not is_nil(last_read_message.id) and
           (message.inserted_at > last_read_message.inserted_at or
              (message.inserted_at == last_read_message.inserted_at and
                 message.id > last_read_message.id))) or
        (is_nil(membership.last_read_message_id) and not is_nil(membership.last_read_at) and
           message.inserted_at > membership.last_read_at) or
        (is_nil(membership.last_read_message_id) and is_nil(membership.last_read_at))
    )
  end

  defp effective_channel_notification_level(%User{} = user, %Channel{} = channel) do
    override =
      Repo.get_by(ChannelNotificationOverride, user_id: user.id, channel_id: channel.id)

    membership =
      Repo.get_by(ChannelMembership, user_id: user.id, channel_id: channel.id)

    cond do
      override && override.level != :default -> override.level
      membership && membership.notification_level != :default -> membership.notification_level
      true -> :default
    end
  end
end
