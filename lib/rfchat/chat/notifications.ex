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

    memberships =
      ChannelMembership
      |> where(
        [membership],
        membership.user_id == ^user.id and membership.channel_id in ^channel_ids
      )
      |> Repo.all()
      |> Map.new(&{&1.channel_id, &1})

    Enum.into(channels, %{}, fn channel ->
      membership = Map.get(memberships, channel.id)
      {channel.id, unread_count_for_channel(channel.id, user.id, membership)}
    end)
  end

  def unread_mentions_for_user(%User{} = user, channels) when is_list(channels) do
    channel_ids = Enum.map(channels, & &1.id)

    memberships =
      ChannelMembership
      |> where(
        [membership],
        membership.user_id == ^user.id and membership.channel_id in ^channel_ids
      )
      |> Repo.all()
      |> Map.new(&{&1.channel_id, &1})

    role_ids =
      Role
      |> join(:inner, [role], member_role in assoc(role, :member_roles))
      |> where([_role, member_role], member_role.user_id == ^user.id)
      |> select([role, _member_role], role.id)
      |> Repo.all()

    Enum.into(channels, %{}, fn channel ->
      membership = Map.get(memberships, channel.id)
      {channel.id, unread_mentions_for_channel(channel.id, user.id, role_ids, membership)}
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

    membership =
      Repo.get_by(ChannelMembership, user_id: user.id, channel_id: channel.id) ||
        %ChannelMembership{user_id: user.id, channel_id: channel.id}

    membership
    |> ChannelMembership.changeset(%{
      joined_at: membership.joined_at || now,
      last_read_message_id: message && message.id,
      last_read_at: last_read_at
    })
    |> Repo.insert_or_update!()
  end

  defp latest_message_for_channel(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id and is_nil(message.deleted_at))
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(1)
    |> Repo.one()
  end

  defp unread_count_for_channel(channel_id, user_id, membership) do
    Message
    |> where([message], message.channel_id == ^channel_id)
    |> where([message], is_nil(message.deleted_at))
    |> where([message], message.author_id != ^user_id)
    |> apply_unread_boundary(membership)
    |> Repo.aggregate(:count)
  end

  defp unread_mentions_for_channel(channel_id, user_id, role_ids, membership) do
    direct_query =
      from(message in Message,
        join: mention in MessageUserMention,
        on: mention.message_id == message.id,
        where: mention.mentioned_user_id == ^user_id,
        where: message.channel_id == ^channel_id,
        where: is_nil(message.deleted_at),
        where: message.author_id != ^user_id,
        select: message.id
      )
      |> apply_unread_boundary(membership)

    role_query =
      if role_ids == [] do
        nil
      else
        from(message in Message,
          join: mention in MessageRoleMention,
          on: mention.message_id == message.id,
          where: mention.mentioned_role_id in ^role_ids,
          where: message.channel_id == ^channel_id,
          where: is_nil(message.deleted_at),
          where: message.author_id != ^user_id,
          select: message.id
        )
        |> apply_unread_boundary(membership)
      end

    [direct_query, role_query]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(MapSet.new(), fn query, acc ->
      query
      |> Repo.all()
      |> MapSet.new()
      |> MapSet.union(acc)
    end)
    |> MapSet.size()
  end

  defp apply_unread_boundary(query, %{last_read_message_id: last_read_message_id})
       when not is_nil(last_read_message_id) do
    case Repo.get(Message, last_read_message_id) do
      %Message{id: message_id, inserted_at: inserted_at} ->
        where(
          query,
          [message],
          message.inserted_at > ^inserted_at or
            (message.inserted_at == ^inserted_at and message.id > ^message_id)
        )

      nil ->
        query
    end
  end

  defp apply_unread_boundary(query, %{last_read_at: %DateTime{} = last_read_at}) do
    where(query, [message], message.inserted_at > ^last_read_at)
  end

  defp apply_unread_boundary(query, _membership), do: query

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
