defmodule Rfchat.Chat do
  @moduledoc """
  Chat domain for the single-guild rfchat deployment model.
  """

  import Ecto.Query, warn: false

  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Channels
  alias Rfchat.Chat.Emojis
  alias Rfchat.Chat.MediaAssets
  alias Rfchat.Chat.Notifications
  alias Rfchat.Chat.ServerConfig
  alias Rfchat.Chat.Threads
  alias Rfchat.Chat.Topics
  alias Rfchat.Chat.Visibility
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.MessageRoleMention
  alias Rfchat.Chat.MessageUserMention
  alias Rfchat.Chat.ModerationCase
  alias Rfchat.Chat.Reaction
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User
  alias Rfchat.Chat.AuditLogEntry
  alias Rfchat.Ephemeral
  alias Rfchat.Repo

  @default_reaction_emojis ["👍", "🔥", "❤️"]

  # What a message read needs to render and serialize. The channel is not here: a read sets it from
  # the decision that allowed the read, so it costs no query.
  @read_preloads [:author, reactions: [emoji: :asset], reply_to: :author]

  # What a write returns and broadcasts. The mention lists are here because the receiver's
  # notification check reads them from the broadcast; reads do not need them.
  @message_preloads [
    :author,
    :channel,
    :user_mentions,
    role_mentions: :mentioned_role,
    reactions: [emoji: :asset],
    reply_to: :author
  ]

  def default_reaction_emojis, do: @default_reaction_emojis
  defdelegate create_server_icon_from_upload(creator, upload), to: MediaAssets
  defdelegate asset_url(asset), to: MediaAssets
  defdelegate get_server_settings(), to: ServerConfig
  defdelegate change_server_settings(server_settings, attrs \\ %{}), to: ServerConfig
  defdelegate update_server_settings(attrs, actor), to: ServerConfig
  defdelegate remove_server_icon(actor), to: ServerConfig
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
  defdelegate list_visible_channels_for_user(user), to: Channels
  defdelegate list_channel_tree_for_user(user), to: Channels
  defdelegate build_channel_tree(channels), to: Channels
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

  @doc """
  Records that the scope's member is typing in a channel or thread. Typing is ephemeral, so
  it takes no membership lock: a decision made now is the decision the announcement uses.
  Needs `:send_messages`. A channel the scope may not view is `{:error, :not_found}`.
  """
  def announce_typing(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- cast_id(channel_id) do
      if Visibility.can?(scope, :send_messages, %Channel{id: channel_id}) do
        _ = Ephemeral.put_typing(channel_id, scope.user_id)
        Topics.broadcast_channel(channel_id, {:typing_started, channel_id, scope.user_id})
        :ok
      else
        refusal(scope, %Channel{id: channel_id})
      end
    end
  end

  def clear_typing(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- cast_id(channel_id) do
      if Visibility.can?(scope, :view_channel, %Channel{id: channel_id}) do
        _ = Ephemeral.remove_typing(channel_id, scope.user_id)
        Topics.broadcast_channel(channel_id, {:typing_stopped, channel_id, scope.user_id})
        :ok
      else
        refusal(scope, %Channel{id: channel_id})
      end
    end
  end

  @doc "Users other than the scope's own who are typing in a channel the scope may view."
  def list_typing_users(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- cast_id(channel_id),
         true <- Visibility.can?(scope, :view_channel, %Channel{id: channel_id}) do
      channel_id
      |> Ephemeral.list_typing_user_ids()
      |> Enum.reject(&(&1 == scope.user_id))
      |> typing_users()
    else
      _ -> []
    end
  end

  defp typing_users([]), do: []

  defp typing_users(user_ids) do
    User
    |> where([user], user.id in ^user_ids)
    |> where([user], is_nil(user.deleted_at))
    |> order_by([user], asc: user.display_name, asc: user.username)
    |> Repo.all()
  end

  @doc """
  The newest `:limit` messages (default 50) in a channel the scope may view, oldest first, as
  `{:ok, messages}`. A missing channel and a hidden one are both `{:error, :not_found}`.
  """
  def list_messages(%Scope{} = scope, channel_id, opts \\ []) do
    with {:ok, channel_id} <- cast_id(channel_id),
         %Channel{} = channel <- Visibility.visible_channel(scope, channel_id) do
      limit = Keyword.get(opts, :limit, 50)

      messages =
        Message
        |> where([message], message.channel_id == ^channel_id)
        |> where([message], is_nil(message.deleted_at))
        |> order_by([message], desc: message.inserted_at, desc: message.id)
        |> limit(^limit)
        |> preload(^@read_preloads)
        |> Repo.all()
        |> Enum.reverse()
        |> Enum.map(&%{&1 | channel: channel})

      {:ok, messages}
    else
      _ -> {:error, :not_found}
    end
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
    |> User.account_changeset(attrs)
    |> Repo.insert()
  end

  def change_message(message, attrs \\ %{}) do
    Message.changeset(message, attrs)
  end

  def change_moderation_action(attrs \\ %{}) do
    {%{}, %{reason: :string, duration_minutes: :integer, action: :string}}
    |> Ecto.Changeset.cast(attrs, [:reason, :duration_minutes, :action])
  end

  @doc """
  Creates a message in a channel or thread the scope may send to, and broadcasts it. The message
  comes back with `@message_preloads`, the same shape the broadcast carries. A channel the scope
  may not view is `{:error, :not_found}`; a visible one it may not send to is `{:error,
  :forbidden}`.
  """
  def create_message(%Scope{} = scope, channel_id, attrs) do
    with {:ok, channel_id} <- cast_id(channel_id),
         {:ok, attrs} <- normalize_message_attrs(attrs) do
      write(fn ->
        with :ok <- authorize_write(scope, :send_messages, %Channel{id: channel_id}),
             :ok <- validate_reply_target(channel_id, attrs),
             :ok <- authorize_message_mentions(scope, channel_id, attrs),
             {:ok, message} <-
               %Message{channel_id: channel_id, author_id: scope.user_id}
               |> Message.create_changeset(attrs)
               |> Repo.insert(),
             :ok <- sync_message_mentions(message) do
          {:ok, reload_message(message.id)}
        end
      end)
      |> broadcast_written(:message_created)
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
          |> Membership.timeout_changeset(timeout_until)
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

  @doc """
  Edits a message the scope authored, and broadcasts it. A message the scope may not view is
  `{:error, :not_found}`. A visible message it may not edit (another author, or a timeout) is
  `{:error, :forbidden}`.
  """
  def update_message(%Scope{} = scope, message_id, attrs) do
    with {:ok, message_id} <- cast_id(message_id),
         {:ok, attrs} <- normalize_message_attrs(attrs) do
      write(fn ->
        with {:ok, message} <- authorize_message_write(scope, :edit_message, message_id),
             :ok <- authorize_message_mentions(scope, message.channel_id, attrs),
             {:ok, updated_message} <-
               message
               |> Message.changeset(attrs)
               |> Ecto.Changeset.put_change(:edited_at, DateTime.utc_now())
               |> Repo.update(),
             :ok <- sync_message_mentions(updated_message) do
          {:ok, reload_message(updated_message.id)}
        end
      end)
      |> broadcast_written(:message_updated)
    end
  end

  @doc """
  Deletes a message's content, keeping the row, and broadcasts the deletion. The author may
  delete their own message; `manage_messages` lets anyone else with view delete it. Refusals
  follow `update_message/3`.
  """
  def delete_message(%Scope{} = scope, message_id) do
    with {:ok, message_id} <- cast_id(message_id) do
      write(fn ->
        with {:ok, message} <- authorize_message_write(scope, :delete_message, message_id),
             now = DateTime.utc_now(),
             {:ok, deleted_message} <-
               message
               |> Ecto.Changeset.change(
                 body: "[message deleted]",
                 deleted_at: now,
                 edited_at: now
               )
               |> Repo.update(),
             :ok <- clear_message_mentions(deleted_message.id) do
          {:ok, reload_message(deleted_message.id)}
        end
      end)
      |> broadcast_written(:message_deleted)
    end
  end

  @doc """
  The message with `message_id`, when the scope may view its channel, or nil. A hidden message and
  a missing one both give nil.
  """
  def get_message(%Scope{} = scope, message_id) do
    with {:ok, message_id} <- cast_id(message_id),
         %Message{} = message <- Visibility.visible_message(scope, message_id) do
      Repo.preload(message, @read_preloads)
    else
      _ -> nil
    end
  end

  @doc """
  The messages among `message_ids` that the scope may view, in the order given. Hidden, missing and
  malformed ids are left out. Each distinct channel is decided once, and the preloads run once for
  the whole list.
  """
  def get_messages(%Scope{} = scope, message_ids) do
    ids =
      message_ids
      |> Enum.flat_map(fn id ->
        case cast_id(id) do
          {:ok, id} -> [id]
          {:error, _} -> []
        end
      end)
      |> Enum.uniq()

    # An `in` over an empty list still runs a query, and callers often pass only nil ids.
    case ids do
      [] -> []
      ids -> visible_messages(scope, ids)
    end
  end

  defp visible_messages(scope, ids) do
    messages = Message |> where([message], message.id in ^ids) |> Repo.all()

    channels =
      messages
      |> Enum.map(& &1.channel_id)
      |> Enum.uniq()
      |> Map.new(&{&1, Visibility.visible_channel(scope, &1)})

    visible_by_id =
      Enum.flat_map(messages, fn message ->
        case Map.get(channels, message.channel_id) do
          nil -> []
          channel -> [{message.id, %{message | channel: channel}}]
        end
      end)
      |> Map.new()

    ids
    |> Enum.flat_map(fn id -> List.wrap(Map.get(visible_by_id, id)) end)
    |> Repo.preload(@read_preloads)
  end

  defdelegate message_mentions_user?(message, user), to: Notifications
  defdelegate mention_notifications_enabled?(user, channel), to: Notifications

  @doc """
  Adds the scope's reaction with this unicode emoji to a message, or removes it when present.
  Refusals follow `update_message/3`. An empty emoji is `{:error, :invalid_emoji}`.
  """
  def toggle_reaction(%Scope{} = scope, message_id, emoji_unicode)
      when is_binary(emoji_unicode) do
    case String.trim(emoji_unicode) do
      "" ->
        {:error, :invalid_emoji}

      emoji_unicode ->
        toggle_reaction_on(scope, message_id, fn _member ->
          {:ok, %{emoji_unicode: emoji_unicode}}
        end)
    end
  end

  # Toggles a reaction with a custom emoji the scope's member may use, by emoji id.
  def toggle_reaction(%Scope{} = scope, message_id, %{"emoji_id" => emoji_id})
      when is_binary(emoji_id) do
    toggle_reaction_on(scope, message_id, fn member ->
      with {:ok, emoji} <- Emojis.fetch_available_emoji_for_user(emoji_id, member) do
        {:ok, %{emoji_id: emoji.id}}
      end
    end)
  end

  # The reaction's key (its emoji) is resolved inside the transaction, after the lock, because
  # a custom emoji's availability depends on the member's current roles.
  defp toggle_reaction_on(scope, message_id, emoji_key) do
    with {:ok, message_id} <- cast_id(message_id) do
      write(fn ->
        with {:ok, message} <- authorize_message_write(scope, :add_reactions, message_id),
             {:ok, key} <- emoji_key.(Visibility.member(scope)),
             {:ok, _reaction} <- toggle_reaction_row(message, scope.user_id, key) do
          {:ok, reload_message(message.id)}
        end
      end)
      |> broadcast_written(:message_updated)
    end
  end

  defp toggle_reaction_row(message, user_id, emoji_key) do
    fields = Map.merge(emoji_key, %{message_id: message.id, user_id: user_id})

    case Repo.get_by(Reaction, Map.to_list(fields)) do
      nil -> %Reaction{} |> Reaction.changeset(fields) |> Repo.insert()
      reaction -> Repo.delete(reaction)
    end
  end

  defdelegate mark_channel_read(user, channel, message \\ nil), to: Notifications

  def can_send_messages?(channel, user),
    do: Visibility.can?(user_scope(user), :send_messages, channel)

  def can_view_channel?(channel, user),
    do: Visibility.can?(user_scope(user), :view_channel, channel)

  def can_create_public_threads?(channel, user),
    do: Visibility.can?(user_scope(user), :create_public_threads, channel)

  def can_send_messages_in_threads?(channel, user),
    do: Visibility.can?(user_scope(user), :send_messages_in_threads, channel)

  def can_add_reactions?(channel, user),
    do: Visibility.can?(user_scope(user), :add_reactions, channel)

  def can_manage_messages?(channel, user),
    do: Visibility.can?(user_scope(user), :manage_messages, channel)

  def can_mention_everyone?(channel, user),
    do: Visibility.can?(user_scope(user), :mention_everyone, channel)

  def can_manage_emojis_and_stickers?(user),
    do: Visibility.can?(user_scope(user), :manage_emojis_and_stickers, :server)

  defdelegate thread_channel?(channel), to: Channel, as: :thread?

  @doc "The number of messages in a channel the scope may view. A hidden channel counts 0, as a missing one does."
  def message_count(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- cast_id(channel_id),
         true <- Visibility.can?(scope, :view_channel, %Channel{id: channel_id}) do
      Message
      |> where([message], message.channel_id == ^channel_id)
      |> Repo.aggregate(:count)
    else
      _ -> 0
    end
  end

  def first_user! do
    Repo.one!(from(user in User, order_by: [asc: user.inserted_at], limit: 1))
  end

  def default_role, do: Repo.get_by(Role, is_default: true)

  defp user_scope(%User{id: user_id}), do: %Scope{user_id: user_id}

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
        {:ok, Map.put(attrs, "metadata", stored_metadata(decoded_metadata))}

      {:error, _reason} ->
        {:error, invalid_metadata_changeset(attrs)}
    end
  end

  # The composer also sends its whole editor document, which nothing reads back. Only the
  # mention entities are stored, so a client cannot fill a row with unbounded data.
  defp stored_metadata(%{} = metadata), do: Map.take(metadata, ["entities"])
  defp stored_metadata(_metadata), do: %{}

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
        |> Membership.deactivate_changeset(now, flags)
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

  # The rule (owner, hierarchy, self and owner targets) lives in `Visibility`, which reads both
  # members from the database for the decision.
  defp authorize_member_moderation(%User{} = actor, %User{} = subject, permission_name) do
    if Visibility.can?(user_scope(actor), {:moderate, permission_name}, subject.id),
      do: :ok,
      else: {:error, :forbidden}
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

  defp sync_message_mentions(%Message{id: message_id, body: body}) do
    clear_message_mentions(message_id)

    mention_tokens = mention_tokens_from_body(body)
    user_ids = MapSet.new(fetch_existing_user_ids(mention_tokens))
    role_ids = MapSet.new(fetch_existing_role_ids(mention_tokens))

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

  defp fetch_existing_user_ids(mention_tokens) do
    usernames = Enum.uniq(mention_tokens)

    User
    |> where([user], user.username in ^usernames)
    |> select([user], user.id)
    |> Repo.all()
  end

  # "@here" and "@everyone" name the default role whatever it is called; other tokens match role
  # names, so a role named "@everyone" is not a mass mention.
  defp fetch_existing_role_ids(mention_tokens) do
    {everyone_tokens, role_tokens} = Enum.split_with(mention_tokens, &everyone_token?/1)
    everyone? = everyone_tokens != []

    role_names =
      role_tokens
      |> Enum.flat_map(&role_name_candidates/1)
      |> Enum.uniq()

    Role
    |> where([role], role.name in ^role_names or (^everyone? and role.is_default))
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

  defp everyone_token?(token), do: String.trim_leading(token, "@") in ["here", "everyone"]

  defp role_name_candidates(token) do
    normalized = String.trim_leading(token, "@")
    [token, normalized, "@#{normalized}"]
  end

  defp valid_binary_id?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_binary_id?(_value), do: false

  # Runs a write in one transaction. The block returns {:ok, value} or {:error, reason}; an error
  # rolls the transaction back, so a refused or failed write changes nothing.
  defp write(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Broadcasts a committed message write. The broadcast happens after the commit, so a receiver
  # never reads a message the database does not hold.
  defp broadcast_written({:ok, %Message{} = message}, event) do
    broadcast_message(event, message)
    {:ok, message}
  end

  defp broadcast_written({:error, reason}, _event), do: {:error, reason}

  defp reload_message(message_id) do
    Message
    |> preload(^@message_preloads)
    |> Repo.get!(message_id)
  end

  # Takes the scope's membership lock and decides `action` on the target (a channel or a message).
  defp authorize_write(scope, action, target) do
    if Visibility.lock_and_can?(scope, action, target),
      do: :ok,
      else: refusal(scope, target)
  end

  # Decides a message write, then locks the message row and reads it. The lock keeps a moderator's
  # delete from committing between the decision and the change. The row is read again with its
  # deleted_at, so a message deleted after the decision is refused.
  defp authorize_message_write(scope, action, message_id) do
    with :ok <- authorize_write(scope, action, %Message{id: message_id}) do
      case lock_live_message(message_id) do
        %Message{} = message -> {:ok, message}
        nil -> {:error, :not_found}
      end
    end
  end

  # The one refusal for every write. A row the scope may not view, and a deleted message, answer as
  # a missing row does. A visible row the scope may not change is forbidden.
  defp refusal(scope, %Channel{id: channel_id}) do
    if Visibility.can?(scope, :view_channel, %Channel{id: channel_id}),
      do: {:error, :forbidden},
      else: {:error, :not_found}
  end

  defp refusal(scope, %Message{id: message_id}) do
    case live_message(message_id) do
      %Message{channel_id: channel_id} -> refusal(scope, %Channel{id: channel_id})
      nil -> {:error, :not_found}
    end
  end

  defp live_message(message_id) do
    Repo.one(
      from(message in Message, where: message.id == ^message_id and is_nil(message.deleted_at))
    )
  end

  defp lock_live_message(message_id) do
    Repo.one(
      from(message in Message,
        where: message.id == ^message_id and is_nil(message.deleted_at),
        lock: "FOR UPDATE"
      )
    )
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp authorize_message_mentions(scope, channel_id, attrs) do
    role_ids = attrs |> mentioned_role_ids() |> Enum.uniq()

    disallowed_role_mentions =
      role_ids
      |> mentioned_roles()
      |> Enum.reject(&(&1.mentionable and not &1.is_default))

    cond do
      disallowed_role_mentions == [] ->
        :ok

      Visibility.can?(scope, :mention_everyone, %Channel{id: channel_id}) ->
        :ok

      true ->
        changeset =
          %Message{}
          |> Message.changeset(attrs)
          |> Ecto.Changeset.add_error(:body, "You do not have permission to mention that role.")

        {:error, changeset}
    end
  end

  defp mentioned_role_ids(attrs) do
    attrs
    |> Map.get("body")
    |> mention_tokens_from_body()
    |> then(&fetch_existing_role_ids/1)
  end

  defp mentioned_roles([]), do: []

  defp mentioned_roles(role_ids) do
    valid_ids = Enum.filter(role_ids, &valid_binary_id?/1)

    Role
    |> where([role], role.id in ^valid_ids)
    |> Repo.all()
  end

  # A reply must name a message in the same channel. A message elsewhere and a missing one get the
  # same error, so the answer does not reveal a message in a channel the author may not view.
  defp validate_reply_target(channel_id, attrs) do
    case normalize_optional_binary_id(Map.get(attrs, "reply_to_id")) do
      nil ->
        :ok

      reply_to_id ->
        with {:ok, reply_to_id} <- Ecto.UUID.cast(reply_to_id),
             true <-
               Repo.exists?(
                 from(message in Message,
                   where: message.id == ^reply_to_id and message.channel_id == ^channel_id
                 )
               ) do
          :ok
        else
          _ ->
            {:error,
             invalid_reply_changeset(attrs, "must reference a message in the same conversation")}
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

  defp broadcast_message(event, %Message{} = message) do
    Topics.broadcast_channel(message.channel_id, {event, message})
  end
end
