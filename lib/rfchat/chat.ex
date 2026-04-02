defmodule Rfchat.Chat do
  @moduledoc """
  Chat domain for the single-guild rfchat deployment model.
  """

  import Ecto.Query, warn: false

  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.ChannelNotificationOverride
  alias Rfchat.Chat.ChannelMembership
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.MessageRoleMention
  alias Rfchat.Chat.MessageUserMention
  alias Rfchat.Chat.Reaction
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User
  alias Rfchat.Chat.UserNotificationSetting
  alias Rfchat.Repo

  @channel_events_topic "chat:channels"

  def list_channels do
    Channel
    |> order_by([channel], asc: channel.position, asc: channel.inserted_at)
    |> Repo.all()
  end

  def list_channel_tree do
    channels = list_channels()
    categories = Enum.filter(channels, &(&1.kind == :category))
    category_ids = MapSet.new(Enum.map(categories, & &1.id))

    uncategorized =
      Enum.filter(
        channels,
        &(visible_text_channel?(&1) and root_level_channel?(&1, category_ids))
      )

    categorized_sections =
      Enum.map(categories, fn category ->
        %{
          category: category,
          channels:
            channels
            |> Enum.filter(&(&1.parent_channel_id == category.id and visible_text_channel?(&1)))
            |> sort_channels()
        }
      end)

    categorized_sections ++
      if uncategorized == [] do
        []
      else
        [%{category: nil, channels: sort_channels(uncategorized)}]
      end
  end

  def composer_mentions do
    users =
      User
      |> where([user], is_nil(user.deleted_at))
      |> order_by([user], asc: user.display_name, asc: user.username)
      |> limit(25)
      |> Repo.all()

    roles =
      Role
      |> order_by([role], desc: role.position, asc: role.name)
      |> limit(10)
      |> Repo.all()

    user_entries =
      Enum.map(users, fn user ->
        %{
          id: user.id,
          label: user.username,
          description: user.display_name,
          type: "user"
        }
      end)

    role_entries =
      Enum.map(roles, fn role ->
        %{
          id: role.id,
          label: String.trim_leading(role.name, "@"),
          description: (role.is_default && "default role") || "role",
          type: "role"
        }
      end)

    user_entries ++ role_entries
  end

  def composer_slash_commands do
    [
      %{id: "shrug", label: "shrug", description: "Insert ¯\\_(ツ)_/¯"},
      %{id: "tableflip", label: "tableflip", description: "Insert (╯°□°）╯︵ ┻━┻"},
      %{id: "code", label: "code", description: "Insert fenced code block"},
      %{id: "giphy", label: "giphy", description: "Insert a GIF-style embed request"}
    ]
  end

  def list_channels_for_user(%User{} = user) do
    visible_channels_for_user(user)
    |> Enum.filter(&visible_text_channel?/1)
  end

  defp visible_channels_for_user(%User{} = user) do
    default_role = default_role()

    Channel
    |> order_by([channel], asc: channel.position, asc: channel.inserted_at)
    |> preload([:permission_overwrites])
    |> Repo.all()
    |> Enum.filter(&Authorization.can_view_channel?(user, &1, default_role))
  end

  def list_channel_tree_for_user(%User{} = user) do
    channels = visible_channels_for_user(user)
    categories = Enum.filter(channels, &(&1.kind == :category))
    category_ids = MapSet.new(Enum.map(categories, & &1.id))

    uncategorized =
      Enum.filter(
        channels,
        &(visible_text_channel?(&1) and root_level_channel?(&1, category_ids))
      )

    categorized_sections =
      Enum.map(categories, fn category ->
        %{
          category: category,
          channels:
            channels
            |> Enum.filter(&(&1.parent_channel_id == category.id and visible_text_channel?(&1)))
            |> sort_channels()
        }
      end)
      |> Enum.reject(&(&1.channels == []))

    categorized_sections ++
      if uncategorized == [] do
        []
      else
        [%{category: nil, channels: sort_channels(uncategorized)}]
      end
  end

  def ensure_channel_memberships_for_user(%User{} = user, channels) when is_list(channels) do
    channel_ids = Enum.map(channels, & &1.id)

    existing_channel_ids =
      ChannelMembership
      |> where(
        [membership],
        membership.user_id == ^user.id and membership.channel_id in ^channel_ids
      )
      |> select([membership], membership.channel_id)
      |> Repo.all()
      |> MapSet.new()

    latest_messages = latest_messages_by_channel(channel_ids)
    now = DateTime.utc_now()

    channels
    |> Enum.reject(&MapSet.member?(existing_channel_ids, &1.id))
    |> Enum.each(fn channel ->
      latest_message =
        case Map.get(latest_messages, channel.id) do
          %Message{author_id: author_id} = message when author_id == user.id -> message
          _ -> nil
        end

      %ChannelMembership{channel_id: channel.id, user_id: user.id}
      |> ChannelMembership.changeset(%{
        joined_at: now,
        last_read_message_id: latest_message && latest_message.id,
        last_read_at: latest_message && latest_message.inserted_at
      })
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:channel_id, :user_id])
    end)

    :ok
  end

  def get_channel!(id), do: Repo.get!(Channel, id)

  def get_channel_by_slug!(slug) do
    Repo.get_by!(Channel, slug: slug)
  end

  def get_channel_by_slug_for_user(slug, %User{} = user) do
    default_role = default_role()

    channel =
      Channel
      |> preload([:permission_overwrites])
      |> Repo.get_by(slug: slug)

    cond do
      is_nil(channel) ->
        {:error, :not_found}

      not visible_text_channel?(channel) ->
        {:error, :not_found}

      Authorization.can_view_channel?(user, channel, default_role) ->
        {:ok, channel}

      true ->
        {:error, :forbidden}
    end
  end

  def create_channel(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  def change_channel(%Channel{} = channel, attrs \\ %{}) do
    Channel.changeset(channel, attrs)
  end

  def update_channel(%Channel{} = channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_channel} ->
        broadcast({:channel_updated, updated_channel})
        {:ok, updated_channel}

      error ->
        error
    end
  end

  def delete_channel(%Channel{} = channel) do
    Repo.delete(channel)
    |> case do
      {:ok, deleted_channel} ->
        broadcast({:channel_deleted, deleted_channel})
        {:ok, deleted_channel}

      error ->
        error
    end
  end

  def reorder_channels(section_attrs) when is_list(section_attrs) do
    Repo.transaction(fn ->
      Enum.with_index(section_attrs)
      |> Enum.each(fn {section, section_index} ->
        category = Map.get(section, :category) || Map.get(section, "category")
        channels = Map.get(section, :channels) || Map.get(section, "channels") || []

        category_id = normalize_optional_binary_id(category)

        if category_id do
          category = Repo.get!(Channel, category_id)

          category
          |> Channel.changeset(%{
            position: section_index * 1_000,
            parent_channel_id: nil,
            kind: :category
          })
          |> Repo.update!()
        end

        Enum.with_index(channels)
        |> Enum.each(fn {channel_id, channel_index} ->
          channel = Repo.get!(Channel, channel_id)

          channel
          |> Channel.changeset(%{
            position: section_index * 1_000 + channel_index + 1,
            parent_channel_id: category_id
          })
          |> Repo.update!()
        end)
      end)
    end)
    |> case do
      {:ok, _result} ->
        broadcast(:channels_reordered)
        {:ok, list_channels()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def default_channel_for_user(%User{} = user) do
    user
    |> list_channels_for_user()
    |> List.first()
  end

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

  def list_messages(channel_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Message
    |> where([message], message.channel_id == ^channel_id)
    |> where([message], is_nil(message.deleted_at))
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(^limit)
    |> preload([:author, :reactions, reply_to: :author])
    |> Repo.all()
    |> Enum.reverse()
  end

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def change_message(message, attrs \\ %{}) do
    Message.changeset(message, attrs)
  end

  def create_message(channel, author, attrs) do
    attrs = normalize_message_attrs(attrs)
    channel = Repo.preload(channel, [:permission_overwrites])

    with :ok <- authorize_message_create(channel, author, attrs) do
      Repo.transaction(fn ->
        with {:ok, message} <-
               %Message{channel_id: channel.id, author_id: author.id}
               |> Message.changeset(attrs)
               |> Repo.insert() do
          :ok = sync_message_mentions(message, attrs)
          Repo.preload(message, [:author, :channel, :reactions, reply_to: :author])
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, message} ->
          broadcast({:message_created, message})
          {:ok, message}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
      {:error, changeset, :changeset} -> {:error, changeset}
    end
  end

  def update_message(%Message{} = message, %User{} = actor, attrs) do
    attrs = normalize_message_attrs(attrs)
    message = Repo.preload(message, channel: [:permission_overwrites])

    if message.author_id == actor.id do
      with :ok <- authorize_message_mentions(message.channel, actor, attrs) do
        Repo.transaction(fn ->
          with {:ok, updated_message} <-
                 message
                 |> Message.changeset(Map.put(attrs, "edited_at", DateTime.utc_now()))
                 |> Repo.update() do
            :ok = sync_message_mentions(updated_message, attrs)
            Repo.preload(updated_message, [:author, :channel, reply_to: :author])
          else
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, updated_message} ->
            broadcast({:message_updated, updated_message})
            {:ok, updated_message}

          {:error, changeset} ->
            {:error, changeset}
        end
      else
        {:error, changeset, :changeset} -> {:error, changeset}
      end
    else
      {:error, :forbidden}
    end
  end

  def delete_message(%Message{} = message, %User{} = actor) do
    message = Repo.preload(message, channel: [:permission_overwrites])

    if message.author_id == actor.id or can_manage_messages?(message.channel, actor) do
      message
      |> Message.changeset(%{
        body: "[message deleted]",
        deleted_at: DateTime.utc_now(),
        edited_at: DateTime.utc_now(),
        metadata: Map.put(message.metadata || %{}, "deleted", true)
      })
      |> Repo.update()
      |> case do
        {:ok, deleted_message} ->
          clear_message_mentions(deleted_message.id)
          broadcast({:message_deleted, deleted_message})
          {:ok, deleted_message}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :forbidden}
    end
  end

  def get_message!(id) do
    Message
    |> preload([:author, :channel, :reactions, reply_to: :author])
    |> Repo.get!(id)
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

  def toggle_reaction(%Message{} = message, %User{} = user, emoji_unicode)
      when is_binary(emoji_unicode) do
    message = Repo.preload(message, channel: [:permission_overwrites])
    emoji_unicode = String.trim(emoji_unicode)

    if emoji_unicode == "" do
      {:error, :invalid_emoji}
    else
      if can_add_reactions?(message.channel, user) do
        case Repo.get_by(Reaction,
               message_id: message.id,
               user_id: user.id,
               emoji_unicode: emoji_unicode
             ) do
          nil ->
            %Reaction{}
            |> Reaction.changeset(%{
              message_id: message.id,
              user_id: user.id,
              emoji_unicode: emoji_unicode
            })
            |> Repo.insert()
            |> case do
              {:ok, _reaction} ->
                message = get_message!(message.id)
                broadcast({:message_updated, message})
                {:ok, message}

              {:error, changeset} ->
                {:error, changeset}
            end

          reaction ->
            Repo.delete!(reaction)
            message = get_message!(message.id)
            broadcast({:message_updated, message})
            {:ok, message}
        end
      else
        {:error, :forbidden}
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

  def subscribe_to_channel_events do
    Phoenix.PubSub.subscribe(Rfchat.PubSub, @channel_events_topic)
  end

  def unsubscribe_from_channel_events do
    Phoenix.PubSub.unsubscribe(Rfchat.PubSub, @channel_events_topic)
  end

  def can_send_messages?(%Channel{} = channel, %User{} = user) do
    channel_permission?(channel, user, :send_messages) and can_view_channel?(channel, user)
  end

  def can_view_channel?(%Channel{} = channel, %User{} = user) do
    channel_permission?(channel, user, :view_channel)
  end

  def can_add_reactions?(%Channel{} = channel, %User{} = user) do
    can_view_channel?(channel, user) and channel_permission?(channel, user, :add_reactions)
  end

  def can_manage_messages?(%Channel{} = channel, %User{} = user) do
    can_view_channel?(channel, user) and channel_permission?(channel, user, :manage_messages)
  end

  def can_mention_everyone?(%Channel{} = channel, %User{} = user) do
    can_view_channel?(channel, user) and channel_permission?(channel, user, :mention_everyone)
  end

  def message_count(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id)
    |> Repo.aggregate(:count)
  end

  def first_user! do
    Repo.one!(from(user in User, order_by: [asc: user.inserted_at], limit: 1))
  end

  def default_role do
    Repo.get_by(Role, is_default: true)
  end

  defp normalize_message_attrs(attrs) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    metadata = Map.get(attrs, "metadata")

    normalized_metadata =
      cond do
        is_map(metadata) -> metadata
        is_binary(metadata) and metadata != "" -> Jason.decode!(metadata)
        true -> %{}
      end

    attrs
    |> Map.put("metadata", normalized_metadata)
  end

  defp sync_message_mentions(%Message{id: message_id, body: body}, attrs) do
    clear_message_mentions(message_id)

    entities =
      attrs
      |> Map.get("metadata", %{})
      |> Map.get("entities", [])

    entity_ids =
      entities
      |> Enum.filter(&(normalize_entity_value(&1, "type") == "mention"))
      |> Enum.map(&normalize_entity_value(&1, "id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    mention_tokens = mention_tokens_from_body(body)

    user_ids =
      MapSet.new(fetch_existing_user_ids(entity_ids, mention_tokens))

    role_ids =
      MapSet.new(fetch_existing_role_ids(entity_ids, mention_tokens))

    Enum.each(user_ids, fn user_id ->
      %MessageUserMention{}
      |> MessageUserMention.changeset(%{message_id: message_id, mentioned_user_id: user_id})
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:message_id, :mentioned_user_id])
    end)

    Enum.each(role_ids, fn role_id ->
      %MessageRoleMention{}
      |> MessageRoleMention.changeset(%{message_id: message_id, mentioned_role_id: role_id})
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:message_id, :mentioned_role_id])
    end)

    :ok
  end

  defp clear_message_mentions(message_id) do
    from(mention in MessageUserMention, where: mention.message_id == ^message_id)
    |> Repo.delete_all()

    from(mention in MessageRoleMention, where: mention.message_id == ^message_id)
    |> Repo.delete_all()

    :ok
  end

  defp fetch_existing_user_ids(entity_ids, mention_tokens) do
    valid_entity_ids = Enum.filter(entity_ids, &valid_binary_id?/1)
    usernames = Enum.uniq(mention_tokens)

    User
    |> where([user], user.id in ^valid_entity_ids or user.username in ^usernames)
    |> select([user], user.id)
    |> Repo.all()
  end

  defp fetch_existing_role_ids(entity_ids, mention_tokens) do
    valid_entity_ids = Enum.filter(entity_ids, &valid_binary_id?/1)

    role_names =
      mention_tokens
      |> Enum.flat_map(&role_name_candidates/1)
      |> Enum.uniq()

    Role
    |> where([role], role.id in ^valid_entity_ids or role.name in ^role_names)
    |> select([role], role.id)
    |> Repo.all()
  end

  defp mention_tokens_from_body(body) when is_binary(body) do
    ~r/(?:^|[^[:alnum:]_])@([[:alnum:]_@-]+)/u
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp mention_tokens_from_body(_body), do: []

  defp role_name_candidates(token) do
    normalized = String.trim_leading(token, "@")
    [token, normalized, "@#{normalized}"]
  end

  defp normalize_entity_value(entity, key) when is_map(entity) do
    case key do
      "type" -> Map.get(entity, "type") || Map.get(entity, :type)
      "id" -> Map.get(entity, "id") || Map.get(entity, :id)
      "label" -> Map.get(entity, "label") || Map.get(entity, :label)
      _ -> Map.get(entity, key)
    end
  end

  defp valid_binary_id?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_binary_id?(_value), do: false

  defp latest_messages_by_channel([]), do: %{}

  defp latest_messages_by_channel(channel_ids) do
    from(message in Message,
      where: message.channel_id in ^channel_ids and is_nil(message.deleted_at),
      distinct: message.channel_id,
      order_by: [asc: message.channel_id, desc: message.inserted_at, desc: message.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.channel_id, &1})
  end

  defp latest_message_for_channel(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id and is_nil(message.deleted_at))
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(1)
    |> Repo.one()
  end

  defp sort_channels(channels) do
    Enum.sort_by(channels, &{&1.position, &1.inserted_at})
  end

  defp root_level_channel?(channel, category_ids) do
    is_nil(channel.parent_channel_id) or
      not MapSet.member?(category_ids, channel.parent_channel_id)
  end

  defp visible_text_channel?(channel) do
    channel.kind not in [:category, :thread_public, :thread_private, :thread_announcement]
  end

  defp channel_permission?(%Channel{} = channel, %User{} = user, permission_name) do
    channel = Repo.preload(channel, [:permission_overwrites])
    user = Repo.preload(user, [:membership, member_roles: :role])

    Authorization.channel_permissions(user, channel, default_role())
    |> Authorization.has_permission?(permission_name)
  end

  defp authorize_message_create(channel, author, attrs) do
    cond do
      not can_send_messages?(channel, author) ->
        {:error, :forbidden}

      true ->
        authorize_message_mentions(channel, author, attrs)
    end
  end

  defp authorize_message_mentions(channel, author, attrs) do
    role_ids = attrs |> mentioned_role_ids() |> Enum.uniq()

    disallowed_role_mentions =
      role_ids
      |> mentioned_roles()
      |> Enum.reject(& &1.mentionable)

    cond do
      disallowed_role_mentions == [] ->
        :ok

      can_mention_everyone?(channel, author) ->
        :ok

      true ->
        changeset =
          %Message{}
          |> Message.changeset(attrs)
          |> Ecto.Changeset.add_error(:body, "You do not have permission to mention that role.")

        {:error, changeset, :changeset}
    end
  end

  defp mentioned_role_ids(attrs) do
    metadata_ids =
      attrs
      |> Map.get("metadata", %{})
      |> Map.get("entities", [])
      |> Enum.filter(&(normalize_entity_value(&1, "type") == "mention"))
      |> Enum.map(&normalize_entity_value(&1, "id"))
      |> Enum.reject(&is_nil/1)

    body_ids =
      attrs
      |> Map.get("body")
      |> mention_tokens_from_body()
      |> then(&fetch_existing_role_ids([], &1))

    metadata_ids ++ body_ids
  end

  defp mentioned_roles([]), do: []

  defp mentioned_roles(role_ids) do
    valid_ids = Enum.filter(role_ids, &valid_binary_id?/1)

    Role
    |> where([role], role.id in ^valid_ids)
    |> Repo.all()
  end

  defp normalize_optional_binary_id(nil), do: nil
  defp normalize_optional_binary_id(""), do: nil
  defp normalize_optional_binary_id(value), do: value

  defp unread_count_for_channel(channel_id, user_id, membership) do
    message_ids =
      Message
      |> where([message], message.channel_id == ^channel_id)
      |> where([message], is_nil(message.deleted_at))
      |> where([message], message.author_id != ^user_id)
      |> order_by([message], asc: message.inserted_at, asc: message.id)
      |> select([message], message.id)
      |> Repo.all()

    case membership && membership.last_read_message_id do
      nil ->
        length(message_ids)

      last_read_message_id ->
        message_ids
        |> Enum.drop_while(&(&1 != last_read_message_id))
        |> case do
          [] -> length(message_ids)
          [_last_read | unread_ids] -> length(unread_ids)
        end
    end
  end

  defp unread_mentions_for_channel(channel_id, user_id, role_ids, membership) do
    unread_message_ids = unread_message_ids_for_channel(channel_id, user_id, membership)

    if unread_message_ids == [] do
      0
    else
      direct_count =
        MessageUserMention
        |> where([mention], mention.mentioned_user_id == ^user_id)
        |> where([mention], mention.message_id in ^unread_message_ids)
        |> select([mention], mention.message_id)
        |> Repo.all()
        |> MapSet.new()

      role_count =
        if role_ids == [] do
          MapSet.new()
        else
          MessageRoleMention
          |> where([mention], mention.mentioned_role_id in ^role_ids)
          |> where([mention], mention.message_id in ^unread_message_ids)
          |> select([mention], mention.message_id)
          |> Repo.all()
          |> MapSet.new()
        end

      direct_count
      |> MapSet.union(role_count)
      |> MapSet.size()
    end
  end

  defp unread_message_ids_for_channel(channel_id, user_id, membership) do
    message_ids =
      Message
      |> where([message], message.channel_id == ^channel_id)
      |> where([message], is_nil(message.deleted_at))
      |> where([message], message.author_id != ^user_id)
      |> order_by([message], asc: message.inserted_at, asc: message.id)
      |> select([message], message.id)
      |> Repo.all()

    case membership && membership.last_read_message_id do
      nil ->
        message_ids

      last_read_message_id ->
        message_ids
        |> Enum.drop_while(&(&1 != last_read_message_id))
        |> case do
          [] -> message_ids
          [_last_read | unread_ids] -> unread_ids
        end
    end
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

  defp broadcast(message) do
    Phoenix.PubSub.broadcast_from(Rfchat.PubSub, self(), @channel_events_topic, message)
  end
end
