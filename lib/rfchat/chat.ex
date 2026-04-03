defmodule Rfchat.Chat do
  @moduledoc """
  Chat domain for the single-guild rfchat deployment model.
  """

  import Ecto.Query, warn: false

  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Channels
  alias Rfchat.Chat.Emojis
  alias Rfchat.Chat.MediaAssets
  alias Rfchat.Chat.Notifications
  alias Rfchat.Chat.Permissions
  alias Rfchat.Chat.ServerConfig
  alias Rfchat.Chat.Threads
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.MessageRoleMention
  alias Rfchat.Chat.MessageUserMention
  alias Rfchat.Chat.ModerationCase
  alias Rfchat.Chat.Reaction
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User
  alias Rfchat.Chat.AuditLogEntry
  alias Rfchat.Repo

  @channel_events_topic "chat:channels"
  @default_reaction_emojis ["👍", "🔥", "❤️"]

  def default_reaction_emojis, do: @default_reaction_emojis
  defdelegate create_server_icon_from_upload(creator, upload), to: MediaAssets
  defdelegate asset_url(asset), to: MediaAssets
  defdelegate get_server_settings(), to: ServerConfig
  defdelegate change_server_settings(server_settings, attrs \\ %{}), to: ServerConfig
  defdelegate update_server_settings(attrs, actor), to: ServerConfig
  defdelegate server_icon_url(settings), to: ServerConfig
  defdelegate default_server_name(), to: ServerConfig

  defdelegate list_channels(), to: Channels

  def list_roles do
    Role
    |> order_by([role], desc: role.position, asc: role.name)
    |> Repo.all()
  end

  defdelegate list_channel_tree(), to: Channels

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

  defdelegate list_custom_emojis(), to: Emojis
  defdelegate list_available_emojis(user), to: Emojis
  defdelegate get_emoji!(id), to: Emojis
  defdelegate change_emoji(emoji, attrs \\ %{}), to: Emojis
  defdelegate create_custom_emoji_from_upload(attrs, creator, upload), to: Emojis
  defdelegate delete_custom_emoji(emoji), to: Emojis

  defdelegate list_channels_for_user(user), to: Channels
  defdelegate list_channel_tree_for_user(user), to: Channels
  defdelegate ensure_channel_memberships_for_user(user, channels), to: Channels
  defdelegate get_channel!(id), to: Channels
  defdelegate get_channel(id), to: Channels
  defdelegate get_channel_by_slug!(slug), to: Channels
  defdelegate get_channel_by_slug_for_user(slug, user), to: Channels
  defdelegate create_channel(attrs), to: Channels
  defdelegate change_channel(channel, attrs \\ %{}), to: Channels
  defdelegate update_channel(channel, attrs), to: Channels
  defdelegate delete_channel(channel), to: Channels
  defdelegate reorder_channels(section_attrs), to: Channels
  defdelegate default_channel_for_user(user), to: Channels
  defdelegate get_user_notification_setting(user), to: Notifications
  defdelegate update_user_notification_setting(user, attrs), to: Notifications
  defdelegate update_channel_membership_notification(user, channel_id, attrs), to: Notifications
  defdelegate unread_counts_for_user(user, channels), to: Notifications
  defdelegate unread_mentions_for_user(user, channels), to: Notifications

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

  defdelegate list_thread_messages(channel_or_id, opts \\ []), to: Threads
  defdelegate list_threads_for_channel(channel_id), to: Threads
  defdelegate thread_summaries_for_channel(channel_id), to: Threads
  defdelegate get_thread_for_starter_message(starter_message_id), to: Threads
  defdelegate get_thread_for_user(thread_id, user), to: Threads

  defdelegate create_public_thread(parent_channel, starter_message, author, attrs \\ %{}),
    to: Threads

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

  defdelegate message_mentions_user?(message_id, user), to: Notifications
  defdelegate mention_notifications_enabled?(user, channel), to: Notifications

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

    with {:ok, emoji} <- Emojis.fetch_available_emoji_for_user(emoji_id, user),
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

  defdelegate mark_channel_read(user, channel, message \\ nil), to: Notifications

  def subscribe_to_channel_events do
    Phoenix.PubSub.subscribe(Rfchat.PubSub, @channel_events_topic)
  end

  def unsubscribe_from_channel_events do
    Phoenix.PubSub.unsubscribe(Rfchat.PubSub, @channel_events_topic)
  end

  defdelegate can_send_messages?(channel, user), to: Permissions
  defdelegate can_view_channel?(channel, user), to: Permissions
  defdelegate can_create_public_threads?(channel, user), to: Permissions
  defdelegate can_send_messages_in_threads?(channel, user), to: Permissions
  defdelegate can_add_reactions?(channel, user), to: Permissions
  defdelegate can_manage_messages?(channel, user), to: Permissions
  defdelegate can_mention_everyone?(channel, user), to: Permissions
  defdelegate can_manage_emojis_and_stickers?(user), to: Permissions
  defdelegate timed_out?(user), to: Permissions

  def message_count(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id)
    |> Repo.aggregate(:count)
  end

  def first_user! do
    Repo.one!(from(user in User, order_by: [asc: user.inserted_at], limit: 1))
  end

  defdelegate default_role(), to: Permissions
  defdelegate moderation_permission?(user, permission_name), to: Permissions

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

  defp normalize_optional_binary_id(nil), do: nil
  defp normalize_optional_binary_id(""), do: nil
  defp normalize_optional_binary_id(value), do: value

  defp broadcast(message) do
    Phoenix.PubSub.broadcast_from(Rfchat.PubSub, self(), @channel_events_topic, message)
  end
end
