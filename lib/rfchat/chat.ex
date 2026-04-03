defmodule Rfchat.Chat do
  @moduledoc """
  Chat domain for the single-guild rfchat deployment model.
  """

  import Ecto.Query, warn: false

  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.ChannelNotificationOverride
  alias Rfchat.Chat.ChannelMembership
  alias Rfchat.Chat.Emoji
  alias Rfchat.Chat.MediaAsset
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.MessageRoleMention
  alias Rfchat.Chat.MessageUserMention
  alias Rfchat.Chat.ModerationCase
  alias Rfchat.Chat.Reaction
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.ServerSettings
  alias Rfchat.Chat.User
  alias Rfchat.Chat.UserNotificationSetting
  alias Rfchat.Chat.AuditLogEntry
  alias Rfchat.Repo

  @channel_events_topic "chat:channels"
  @emoji_upload_dir "uploads/emojis"
  @server_icon_upload_dir "uploads/server_icons"
  @allowed_emoji_content_types ~w(image/png image/jpeg image/gif image/webp)
  @default_reaction_emojis ["👍", "🔥", "❤️"]

  def default_reaction_emojis, do: @default_reaction_emojis

  def get_server_settings do
    ServerSettings
    |> preload([:icon_asset])
    |> Repo.one()
    |> case do
      nil ->
        %ServerSettings{name: default_server_name(), singleton: true}

      settings ->
        settings
    end
  end

  def change_server_settings(%ServerSettings{} = server_settings, attrs \\ %{}) do
    ServerSettings.changeset(server_settings, attrs)
  end

  def update_server_settings(attrs, %User{} = actor) when is_map(attrs) do
    server_settings =
      ServerSettings
      |> preload([:icon_asset])
      |> Repo.one()
      |> case do
        nil -> %ServerSettings{}
        settings -> settings
      end

    attrs = Map.put_new(attrs, "name", default_server_name())

    Repo.transaction(fn ->
      previous_icon_asset = server_settings.icon_asset

      with {:ok, icon_asset_id, _icon_asset} <- maybe_persist_server_icon(attrs, actor),
           attrs <- persistable_server_settings_attrs(attrs, icon_asset_id),
           {:ok, settings} <-
             server_settings
             |> ServerSettings.changeset(attrs)
             |> Repo.insert_or_update() do
        settings = Repo.preload(settings, [:icon_asset])

        if not is_nil(previous_icon_asset) and icon_asset_id != :keep and
             previous_icon_asset.id != icon_asset_id do
          delete_media_asset(previous_icon_asset)
        end

        settings
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {:error, reason, :upload} -> Repo.rollback({:upload, reason})
      end
    end)
    |> case do
      {:ok, settings} -> {:ok, settings}
      {:error, {:upload, reason}} -> {:error, reason}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def server_icon_url(%ServerSettings{icon_asset: %MediaAsset{} = asset}), do: asset_url(asset)
  def server_icon_url(%ServerSettings{icon_asset: %Ecto.Association.NotLoaded{}}), do: nil
  def server_icon_url(_settings), do: nil

  def default_server_name do
    Application.get_env(:rfchat, :guild_name, "RFChat")
  end

  def list_channels do
    Channel
    |> order_by([channel], asc: channel.position, asc: channel.inserted_at)
    |> Repo.all()
  end

  def list_roles do
    Role
    |> order_by([role], desc: role.position, asc: role.name)
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

  def list_custom_emojis do
    Emoji
    |> order_by([emoji], asc: emoji.name, asc: emoji.inserted_at)
    |> preload([:asset, :creator, :emoji_roles])
    |> Repo.all()
  end

  def list_available_emojis(%User{} = user) do
    user = Repo.preload(user, [:membership, member_roles: :role])
    role_ids = MapSet.new(Enum.map(user.member_roles || [], & &1.role_id))

    list_custom_emojis()
    |> Enum.filter(&emoji_available_to_user?(&1, user, role_ids))
  end

  def get_emoji!(id) do
    Emoji
    |> preload([:asset, :creator, :emoji_roles])
    |> Repo.get!(id)
  end

  def change_emoji(%Emoji{} = emoji, attrs \\ %{}) do
    Emoji.changeset(emoji, attrs)
  end

  def create_custom_emoji_from_upload(attrs, %User{} = creator, upload) when is_map(attrs) do
    attrs = normalize_emoji_attrs(attrs)

    Repo.transaction(fn ->
      with {:ok, asset} <- create_media_asset_from_upload(upload, creator),
           {:ok, emoji} <-
             %Emoji{creator_id: creator.id}
             |> Emoji.changeset(Map.put(attrs, "asset_id", asset.id))
             |> Repo.insert() do
        Repo.preload(emoji, [:asset, :creator, :emoji_roles])
      else
        {:error, changeset} -> Repo.rollback(changeset)
        {:error, reason, :upload} -> Repo.rollback({:upload, reason})
      end
    end)
    |> case do
      {:ok, emoji} -> {:ok, emoji}
      {:error, {:upload, reason}} -> {:error, reason}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def create_server_icon_from_upload(%User{} = creator, upload) do
    create_media_asset_from_upload(upload, creator,
      allowed_types: @allowed_emoji_content_types,
      upload_dir: @server_icon_upload_dir,
      kind: :server_icon
    )
  end

  def delete_custom_emoji(%Emoji{} = emoji) do
    emoji = Repo.preload(emoji, [:asset])

    Repo.transaction(fn ->
      {:ok, deleted_emoji} = Repo.delete(emoji)

      case deleted_emoji.asset do
        %MediaAsset{} = asset ->
          maybe_delete_asset_file(asset)
          Repo.delete(asset)

        _ ->
          {:ok, nil}
      end

      deleted_emoji
    end)
    |> case do
      {:ok, deleted_emoji} -> {:ok, deleted_emoji}
      {:error, reason} -> {:error, reason}
    end
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

  def get_channel(id), do: Repo.get(Channel, id)

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
    |> case do
      {:ok, channel} ->
        broadcast({:channel_created, channel})
        {:ok, channel}

      error ->
        error
    end
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

  def list_messages(channel_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Message
    |> where([message], message.channel_id == ^channel_id)
    |> where([message], is_nil(message.deleted_at))
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(^limit)
    |> preload([:author, reactions: [emoji: :asset], reply_to: :author])
    |> Repo.all()
    |> Enum.reverse()
  end

  def list_thread_messages(channel_or_id, opts \\ [])

  def list_thread_messages(%Channel{id: channel_id}, opts),
    do: list_thread_messages(channel_id, opts)

  def list_thread_messages(channel_id, opts) do
    list_messages(channel_id, opts)
  end

  def list_threads_for_channel(channel_id) do
    Channel
    |> where(
      [channel],
      channel.parent_channel_id == ^channel_id and channel.kind == :thread_public and
        is_nil(channel.archived_at)
    )
    |> order_by([channel], asc: channel.inserted_at, asc: channel.id)
    |> preload([:parent_channel, starter_message: :author])
    |> Repo.all()
  end

  def thread_summaries_for_channel(channel_id) do
    threads = list_threads_for_channel(channel_id)
    thread_ids = Enum.map(threads, & &1.id)

    reply_counts =
      if thread_ids == [] do
        %{}
      else
        from(message in Message,
          where: message.channel_id in ^thread_ids and is_nil(message.deleted_at),
          group_by: message.channel_id,
          select: {message.channel_id, count(message.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    Enum.into(threads, %{}, fn thread ->
      {thread.starter_message_id,
       %{
         thread: thread,
         reply_count: Map.get(reply_counts, thread.id, 0)
       }}
    end)
  end

  def get_thread_for_starter_message(starter_message_id) do
    Channel
    |> where(
      [channel],
      channel.starter_message_id == ^starter_message_id and channel.kind == :thread_public and
        is_nil(channel.archived_at)
    )
    |> preload([:parent_channel, starter_message: :author])
    |> Repo.one()
  end

  def get_thread_for_user(thread_id, %User{} = user) do
    thread = get_channel(thread_id)

    cond do
      is_nil(thread) ->
        {:error, :not_found}

      not thread_channel?(thread) ->
        {:error, :not_found}

      can_view_channel?(thread, user) ->
        {:ok, Repo.preload(thread, [:parent_channel, starter_message: :author])}

      true ->
        {:error, :forbidden}
    end
  end

  def create_public_thread(
        %Channel{} = parent_channel,
        %Message{} = starter_message,
        %User{} = author,
        attrs \\ %{}
      ) do
    parent_channel = Repo.preload(parent_channel, [:permission_overwrites])
    author = Repo.preload(author, [:membership, member_roles: :role])
    starter_message = Repo.preload(starter_message, [:author, :channel])

    with :ok <- authorize_public_thread_create(parent_channel, starter_message, author) do
      case get_thread_for_starter_message(starter_message.id) do
        %Channel{} = thread ->
          {:ok, thread}

        nil ->
          attrs = normalize_thread_attrs(attrs, starter_message, parent_channel)

          Repo.transaction(fn ->
            with {:ok, thread} <-
                   %Channel{created_by_id: author.id}
                   |> Channel.changeset(attrs)
                   |> Repo.insert() do
              :ok = ensure_channel_memberships_for_user(author, [thread])
              Repo.preload(thread, [:parent_channel, starter_message: :author])
            else
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)
          |> case do
            {:ok, thread} ->
              broadcast({:channel_created, thread})
              {:ok, thread}

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    end
  end

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def change_message(message, attrs \\ %{}) do
    Message.changeset(message, attrs)
  end

  def change_moderation_action(attrs \\ %{}) do
    {%{}, %{reason: :string, duration_minutes: :integer, action: :string}}
    |> Ecto.Changeset.cast(attrs, [:reason, :duration_minutes, :action])
  end

  def create_message(channel, author, attrs) do
    channel = Repo.preload(channel, [:permission_overwrites])

    with {:ok, attrs} <- normalize_message_attrs(attrs),
         :ok <- authorize_message_create(channel, author, attrs) do
      Repo.transaction(fn ->
        with {:ok, message} <-
               %Message{channel_id: channel.id, author_id: author.id}
               |> Message.changeset(attrs)
               |> Repo.insert() do
          :ok = sync_message_mentions(message, attrs)

          Repo.preload(message, [:author, :channel, reactions: [emoji: :asset], reply_to: :author])
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

  def list_moderation_cases_for_user(user_id) do
    ModerationCase
    |> where([moderation_case], moderation_case.subject_user_id == ^user_id)
    |> order_by([moderation_case], desc: moderation_case.inserted_at)
    |> preload([:actor_user, :subject_user])
    |> Repo.all()
  end

  def timeout_member(%User{} = actor, %User{} = subject, duration_minutes, reason \\ nil)
      when is_integer(duration_minutes) and duration_minutes > 0 do
    with :ok <- authorize_member_moderation(actor, subject, :moderate_members) do
      timeout_until = DateTime.add(DateTime.utc_now(), duration_minutes * 60, :second)

      Repo.transaction(fn ->
        membership = Repo.preload(subject, [:membership]).membership || Repo.rollback(:not_member)

        {:ok, membership} =
          membership
          |> Membership.changeset(%{timeout_until: timeout_until})
          |> Repo.update()

        moderation_case =
          record_moderation_case(actor, subject, :timeout, reason,
            expires_at: timeout_until,
            executed_at: DateTime.utc_now(),
            details: %{"duration_minutes" => duration_minutes}
          )

        record_audit_log!(actor, subject, "timeout_member", reason, %{
          "duration_minutes" => duration_minutes,
          "timeout_until" => timeout_until
        })

        {Repo.preload(subject, [:membership, member_roles: :role])
         |> Map.put(:membership, membership), moderation_case}
      end)
      |> case do
        {:ok, {updated_subject, moderation_case}} -> {:ok, updated_subject, moderation_case}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def kick_member(%User{} = actor, %User{} = subject, reason \\ nil) do
    with :ok <- authorize_member_moderation(actor, subject, :kick_members) do
      deactivate_member(actor, subject, :kick, reason, %{"kicked" => true})
    end
  end

  def ban_member(%User{} = actor, %User{} = subject, reason \\ nil) do
    with :ok <- authorize_member_moderation(actor, subject, :ban_members) do
      deactivate_member(actor, subject, :ban, reason, %{"banned" => true, "ban_reason" => reason})
    end
  end

  def update_message(%Message{} = message, %User{} = actor, attrs) do
    message = Repo.preload(message, channel: [:permission_overwrites])

    if message.author_id == actor.id do
      with {:ok, attrs} <- normalize_message_attrs(attrs),
           :ok <- authorize_message_mentions(message.channel, actor, attrs) do
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
    |> preload([:author, :channel, reactions: [emoji: :asset], reply_to: :author])
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

  def toggle_reaction(%Message{} = message, %User{} = user, %{"emoji_id" => emoji_id})
      when is_binary(emoji_id) do
    message = Repo.preload(message, channel: [:permission_overwrites])

    with {:ok, emoji} <- fetch_available_emoji_for_user(emoji_id, user),
         true <- can_add_reactions?(message.channel, user) do
      case Repo.get_by(Reaction, message_id: message.id, user_id: user.id, emoji_id: emoji.id) do
        nil ->
          %Reaction{}
          |> Reaction.changeset(%{
            message_id: message.id,
            user_id: user.id,
            emoji_id: emoji.id
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
      false -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
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
    cond do
      thread_channel?(channel) ->
        can_send_messages_in_threads?(channel, user)

      true ->
        not timed_out?(user) and channel_permission?(channel, user, :send_messages) and
          can_view_channel?(channel, user)
    end
  end

  def can_view_channel?(%Channel{} = channel, %User{} = user) do
    cond do
      thread_channel?(channel) ->
        can_view_thread_channel?(channel, user)

      true ->
        channel_permission?(channel, user, :view_channel)
    end
  end

  def can_create_public_threads?(%Channel{} = channel, %User{} = user) do
    thread_host_channel?(channel) and not timed_out?(user) and can_send_messages?(channel, user) and
      channel_permission?(channel, user, :create_public_threads)
  end

  def can_send_messages_in_threads?(%Channel{} = channel, %User{} = user) do
    if thread_channel?(channel) do
      not timed_out?(user) and can_view_thread_channel?(channel, user) and
        channel_permission?(channel, user, :send_messages_in_threads) and
        thread_parent_allows_messages?(channel, user)
    else
      false
    end
  end

  def can_add_reactions?(%Channel{} = channel, %User{} = user) do
    not timed_out?(user) and can_view_channel?(channel, user) and
      channel_permission?(channel, user, :add_reactions)
  end

  def can_manage_messages?(%Channel{} = channel, %User{} = user) do
    can_view_channel?(channel, user) and channel_permission?(channel, user, :manage_messages)
  end

  def can_mention_everyone?(%Channel{} = channel, %User{} = user) do
    can_view_channel?(channel, user) and channel_permission?(channel, user, :mention_everyone)
  end

  def can_manage_emojis_and_stickers?(%User{} = user) do
    permissions =
      user
      |> Repo.preload([:membership, member_roles: :role])
      |> Authorization.base_permissions(default_role())

    Authorization.has_permission?(permissions, :manage_emojis_and_stickers) or
      Authorization.has_permission?(permissions, :administrator)
  end

  def timed_out?(%User{membership: %{timeout_until: timeout_until}})
      when not is_nil(timeout_until) do
    DateTime.compare(timeout_until, DateTime.utc_now()) == :gt
  end

  def timed_out?(%User{}), do: false

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

  def moderation_permission?(%User{} = user, permission_name) do
    permissions =
      user
      |> Repo.preload([:membership, member_roles: :role])
      |> Authorization.base_permissions(default_role())

    Authorization.has_permission?(permissions, permission_name) or
      Authorization.has_permission?(permissions, :administrator)
  end

  def asset_url(%MediaAsset{storage_key: storage_key}) when is_binary(storage_key),
    do: "/#{storage_key}"

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
        is_map(metadata) -> {:ok, metadata}
        is_binary(metadata) and metadata != "" -> Jason.decode(metadata)
        true -> {:ok, %{}}
      end

    case normalized_metadata do
      {:ok, decoded_metadata} ->
        {:ok, Map.put(attrs, "metadata", decoded_metadata)}

      {:error, _reason} ->
        {:error, invalid_metadata_changeset(attrs)}
    end
  end

  defp invalid_metadata_changeset(attrs) do
    %Message{}
    |> Message.changeset(Map.put(attrs, "body", Map.get(attrs, "body", "")))
    |> Ecto.Changeset.add_error(:metadata, "must be valid JSON")
  end

  defp normalize_emoji_attrs(attrs) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    name = String.trim(Map.get(attrs, "name", ""))
    shortcode = Map.get(attrs, "shortcode") |> blank_to_nil() |> normalize_shortcode(name)

    attrs
    |> Map.put("name", name)
    |> Map.put("shortcode", shortcode)
    |> Map.put_new("requires_colons", true)
    |> Map.put_new("available", true)
    |> Map.put_new("listed", true)
  end

  defp normalize_shortcode(nil, name), do: normalize_shortcode(name, name)

  defp normalize_shortcode(value, _name) when is_binary(value) do
    normalized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_+-]+/u, "_")
      |> String.trim("_:")

    if normalized == "", do: nil, else: ":#{normalized}:"
  end

  defp create_media_asset_from_upload(
         %{path: path, client_name: client_name, client_type: client_type},
         %User{} = creator,
         opts \\ []
       ) do
    allowed_types = Keyword.get(opts, :allowed_types, @allowed_emoji_content_types)
    upload_dir = Keyword.get(opts, :upload_dir, @emoji_upload_dir)
    kind = Keyword.get(opts, :kind, :emoji)

    with :ok <- validate_upload_type(client_type, allowed_types),
         {:ok, %{size: byte_size}} <- File.stat(path),
         ext <- upload_extension(client_name, client_type),
         storage_key <- Path.join(upload_dir, "#{Ecto.UUID.generate()}#{ext}"),
         destination <- asset_destination_path(storage_key),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(path, destination),
         {:ok, sha256} <- file_sha256(destination),
         {:ok, asset} <-
           %MediaAsset{}
           |> MediaAsset.changeset(%{
             uploader_id: creator.id,
             kind: kind,
             storage_key: storage_key,
             original_filename: client_name,
             content_type: client_type,
             byte_size: byte_size,
             sha256: sha256
           })
           |> Repo.insert() do
      {:ok, asset}
    else
      {:error, reason} -> {:error, reason, :upload}
    end
  end

  defp validate_upload_type(content_type, allowed_types) do
    if content_type in allowed_types, do: :ok, else: {:error, :invalid_upload_type}
  end

  defp maybe_persist_server_icon(attrs, actor) do
    case Map.get(attrs, "icon_upload") do
      nil ->
        if Map.has_key?(attrs, "icon_asset_id") do
          {:ok, blank_to_nil(Map.get(attrs, "icon_asset_id")), nil}
        else
          {:ok, :keep, nil}
        end

      upload ->
        case create_server_icon_from_upload(actor, upload) do
          {:ok, asset} -> {:ok, asset.id, asset}
          {:error, reason, :upload} -> {:error, reason, :upload}
          {:error, reason} -> {:error, reason, :upload}
        end
    end
  end

  defp persistable_server_settings_attrs(attrs, icon_asset_id) do
    attrs =
      attrs
      |> Map.take(["name"])
      |> Map.put("singleton", true)

    if icon_asset_id == :keep do
      attrs
    else
      Map.put(attrs, "icon_asset_id", blank_to_nil(icon_asset_id))
    end
  end

  defp delete_media_asset(%MediaAsset{} = asset) do
    maybe_delete_asset_file(asset)
    Repo.delete(asset)
  end

  defp upload_extension(filename, content_type) do
    ext = filename |> Path.extname() |> String.downcase()

    case ext do
      ".png" -> ext
      ".jpg" -> ext
      ".jpeg" -> ext
      ".gif" -> ext
      ".webp" -> ext
      _ -> extension_for_content_type(content_type)
    end
  end

  defp extension_for_content_type("image/png"), do: ".png"
  defp extension_for_content_type("image/jpeg"), do: ".jpg"
  defp extension_for_content_type("image/gif"), do: ".gif"
  defp extension_for_content_type("image/webp"), do: ".webp"
  defp extension_for_content_type(_), do: ".bin"

  defp asset_destination_path(storage_key) do
    Application.app_dir(:rfchat, Path.join(["priv", "static", storage_key]))
  end

  defp file_sha256(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_delete_asset_file(%MediaAsset{storage_key: storage_key})
       when is_binary(storage_key) do
    storage_key
    |> asset_destination_path()
    |> File.rm()

    :ok
  end

  defp fetch_available_emoji_for_user(emoji_id, %User{} = user) do
    emoji = get_emoji!(emoji_id)

    if emoji_available_to_user?(emoji, Repo.preload(user, [:membership, member_roles: :role])) do
      {:ok, emoji}
    else
      {:error, :forbidden}
    end
  rescue
    Ecto.NoResultsError -> {:error, :invalid_emoji}
  end

  defp emoji_available_to_user?(%Emoji{} = emoji, %User{} = user, role_ids \\ nil) do
    role_ids = role_ids || MapSet.new(Enum.map(user.member_roles || [], & &1.role_id))

    cond do
      not emoji.available ->
        false

      user.membership && user.membership.is_owner ->
        true

      can_manage_emojis_and_stickers?(user) ->
        true

      emoji.emoji_roles == [] ->
        emoji.listed

      true ->
        emoji.listed and Enum.any?(emoji.emoji_roles, &MapSet.member?(role_ids, &1.role_id))
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp deactivate_member(%User{} = actor, %User{} = subject, action_type, reason, extra_flags) do
    Repo.transaction(fn ->
      membership = Repo.preload(subject, [:membership]).membership || Repo.rollback(:not_member)
      now = DateTime.utc_now()
      flags = Map.merge(membership.flags || %{}, extra_flags)

      {:ok, membership} =
        membership
        |> Membership.changeset(%{
          deactivated_at: now,
          timeout_until: nil,
          flags: flags
        })
        |> Repo.update()

      moderation_case =
        record_moderation_case(actor, subject, action_type, reason,
          executed_at: now,
          details: flags
        )

      record_audit_log!(actor, subject, "#{action_type}_member", reason, flags)

      {Repo.preload(subject, [:membership, member_roles: :role])
       |> Map.put(:membership, membership), moderation_case}
    end)
    |> case do
      {:ok, {updated_subject, moderation_case}} -> {:ok, updated_subject, moderation_case}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_member_moderation(%User{} = actor, %User{} = subject, permission_name) do
    actor = Repo.preload(actor, [:membership, member_roles: :role])
    subject = Repo.preload(subject, [:membership, member_roles: :role])

    cond do
      actor.id == subject.id -> {:error, :forbidden}
      subject.membership && subject.membership.is_owner -> {:error, :forbidden}
      not moderation_permission?(actor, permission_name) -> {:error, :forbidden}
      true -> :ok
    end
  end

  defp record_moderation_case(%User{} = actor, %User{} = subject, action_type, reason, attrs) do
    attrs = %{
      action_type: action_type,
      state: :executed,
      actor_user_id: actor.id,
      subject_user_id: subject.id,
      reason: reason,
      details: Keyword.get(attrs, :details, %{}),
      expires_at: Keyword.get(attrs, :expires_at),
      executed_at: Keyword.get(attrs, :executed_at)
    }

    do_insert_moderation_case(attrs, 5)
  end

  defp do_insert_moderation_case(attrs, attempts_left) when attempts_left > 0 do
    case_number = next_case_number()

    case %ModerationCase{}
         |> ModerationCase.changeset(Map.put(attrs, :case_number, case_number))
         |> Repo.insert() do
      {:ok, moderation_case} ->
        moderation_case

      {:error, changeset} ->
        if unique_case_number_error?(changeset) do
          do_insert_moderation_case(attrs, attempts_left - 1)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp do_insert_moderation_case(_attrs, 0) do
    raise "failed to allocate a unique moderation case number"
  end

  defp unique_case_number_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:case_number, _details} -> true
      _other -> false
    end)
  end

  defp record_audit_log!(%User{} = actor, %User{} = subject, action_type, reason, metadata) do
    %AuditLogEntry{}
    |> AuditLogEntry.changeset(%{
      action_type: action_type,
      actor_user_id: actor.id,
      subject_user_id: subject.id,
      target_type: "user",
      target_id: subject.id,
      reason: reason,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp next_case_number do
    (Repo.aggregate(ModerationCase, :max, :case_number) || 0) + 1
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

  defp thread_channel?(%Channel{kind: kind}),
    do: kind in [:thread_public, :thread_private, :thread_announcement]

  defp thread_host_channel?(%Channel{kind: kind}), do: kind in [:text, :announcement, :forum]

  defp thread_parent_channel(%Channel{} = channel) do
    channel = Repo.preload(channel, [:parent_channel])
    channel.parent_channel
  end

  defp can_view_thread_channel?(%Channel{} = channel, %User{} = user) do
    case thread_parent_channel(channel) do
      %Channel{} = parent_channel ->
        can_view_channel?(parent_channel, user) and
          channel_permission?(channel, user, :view_channel)

      _ ->
        false
    end
  end

  defp thread_parent_allows_messages?(%Channel{} = channel, %User{} = user) do
    case thread_parent_channel(channel) do
      %Channel{} = parent_channel -> can_send_messages?(parent_channel, user)
      _ -> false
    end
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
        with :ok <- validate_reply_target(channel, attrs) do
          authorize_message_mentions(channel, author, attrs)
        end
    end
  end

  defp authorize_public_thread_create(
         %Channel{} = parent_channel,
         %Message{} = starter_message,
         %User{} = author
       ) do
    cond do
      starter_message.channel_id != parent_channel.id ->
        {:error,
         invalid_thread_changeset(
           parent_channel,
           starter_message,
           "starter message must belong to that channel"
         )}

      not thread_host_channel?(parent_channel) ->
        {:error,
         invalid_thread_changeset(
           parent_channel,
           starter_message,
           "threads can only start from text-like channels"
         )}

      not can_create_public_threads?(parent_channel, author) ->
        {:error, :forbidden}

      deleted_message?(starter_message) ->
        {:error,
         invalid_thread_changeset(
           parent_channel,
           starter_message,
           "cannot start a thread from a deleted message"
         )}

      true ->
        :ok
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

  defp validate_reply_target(%Channel{} = channel, attrs) do
    case normalize_optional_binary_id(Map.get(attrs, "reply_to_id")) do
      nil ->
        :ok

      reply_to_id ->
        case Repo.get(Message, reply_to_id) do
          %Message{} = reply_to when reply_to.channel_id == channel.id ->
            :ok

          %Message{} ->
            {:error,
             invalid_reply_changeset(attrs, "must reference a message in the same conversation"),
             :changeset}

          nil ->
            {:error, invalid_reply_changeset(attrs, "does not exist"), :changeset}
        end
    end
  end

  defp invalid_reply_changeset(attrs, message) do
    %Message{}
    |> Message.changeset(Map.put(attrs, "body", Map.get(attrs, "body", "")))
    |> Ecto.Changeset.add_error(:reply_to_id, message)
  end

  defp invalid_thread_changeset(parent_channel, starter_message, message) do
    %Channel{created_by_id: starter_message.author_id}
    |> Channel.changeset(normalize_thread_attrs(%{}, starter_message, parent_channel))
    |> Ecto.Changeset.add_error(:starter_message_id, message)
  end

  defp normalize_thread_attrs(attrs, starter_message, parent_channel) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    parent_channel = parent_channel || starter_message.channel

    attrs
    |> Map.put_new("name", thread_name_from_message(starter_message))
    |> Map.put_new("slug", "thread-#{Ecto.UUID.generate()}")
    |> Map.put_new("kind", :thread_public)
    |> Map.put_new("position", next_thread_position(parent_channel.id))
    |> Map.put_new("parent_channel_id", parent_channel.id)
    |> Map.put_new("starter_message_id", starter_message.id)
    |> Map.put_new("topic", nil)
  end

  defp thread_name_from_message(%Message{body: body}) do
    body
    |> String.trim()
    |> case do
      "" -> "Thread"
      value -> String.slice(value, 0, 40)
    end
  end

  defp next_thread_position(parent_channel_id) do
    from(channel in Channel,
      where: channel.parent_channel_id == ^parent_channel_id and channel.kind == :thread_public,
      select: max(channel.position)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end

  defp normalize_optional_binary_id(nil), do: nil
  defp normalize_optional_binary_id(""), do: nil
  defp normalize_optional_binary_id(value), do: value

  defp deleted_message?(%Message{} = message) do
    not is_nil(message.deleted_at) or Map.get(message.metadata || %{}, "deleted", false)
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

  defp broadcast(message) do
    Phoenix.PubSub.broadcast_from(Rfchat.PubSub, self(), @channel_events_topic, message)
  end
end
