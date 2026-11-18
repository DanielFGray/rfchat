defmodule Tavern.Chat do
  @moduledoc """
  Chat domain for the single-guild tavern deployment model.
  """

  import Ecto.Query, warn: false

  alias Tavern.Accounts
  alias Tavern.Accounts.Scope
  alias Tavern.Chat.Channel
  alias Tavern.Chat.ChannelOverwrites
  alias Tavern.Chat.Channels
  alias Tavern.Chat.Emojis
  alias Tavern.Chat.MediaAssets
  alias Tavern.Chat.Notifications
  alias Tavern.Chat.Roles
  alias Tavern.Chat.ServerConfig
  alias Tavern.Chat.Threads
  alias Tavern.Chat.Topics
  alias Tavern.Chat.Visibility
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Message
  alias Tavern.Chat.MessageRoleMention
  alias Tavern.Chat.MessageUserMention
  alias Tavern.Chat.ModerationCase
  alias Tavern.Chat.Reaction
  alias Tavern.Chat.Role
  alias Tavern.Chat.User
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Ephemeral
  alias Tavern.Repo

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

  defdelegate list_channels(scope), to: Channels

  defdelegate list_roles(scope), to: Roles
  defdelegate role_controls(scope), to: Roles
  defdelegate member_roles(scope, user_id), to: Roles
  defdelegate change_role(role, attrs \\ %{}), to: Roles
  defdelegate create_role(scope, attrs), to: Roles
  defdelegate update_role(scope, role_id, attrs), to: Roles
  defdelegate delete_role(scope, role_id), to: Roles
  defdelegate move_role(scope, role_id, direction), to: Roles
  defdelegate add_member_role(scope, user_id, role_id), to: Roles
  defdelegate remove_member_role(scope, user_id, role_id), to: Roles
  defdelegate list_overwrites(scope, channel_id), to: ChannelOverwrites
  defdelegate overwrite_controls(scope, channel_id), to: ChannelOverwrites
  defdelegate put_overwrite(scope, channel_id, target, allow, deny), to: ChannelOverwrites
  defdelegate delete_overwrite(scope, channel_id, target), to: ChannelOverwrites

  defdelegate list_channel_tree(scope), to: Channels

  @doc """
  The mention candidates for the composer: active members, then roles. A scope that is not an
  active member gets none, and a banned, removed or deleted user is not a candidate.
  """
  def composer_mentions(%Scope{} = scope) do
    if is_nil(Visibility.member(scope)), do: [], else: mention_candidates()
  end

  defp mention_candidates do
    users =
      User
      |> join(:inner, [user], membership in Membership, on: membership.user_id == user.id)
      |> where([user, membership], is_nil(user.deleted_at) and is_nil(membership.deactivated_at))
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

  defdelegate build_channel_tree(channels), to: Channels
  defdelegate ensure_channel_memberships(scope, channels), to: Channels
  defdelegate get_channel(scope, id), to: Channels
  defdelegate get_channel_by_slug(scope, slug), to: Channels
  defdelegate create_channel(scope, attrs), to: Channels
  defdelegate change_channel(channel, attrs \\ %{}), to: Channels
  defdelegate update_channel(scope, channel_id, attrs), to: Channels
  defdelegate delete_channel(scope, channel_id), to: Channels
  defdelegate move_channel(scope, channel_id, direction), to: Channels
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
        typing_refusal(scope, channel_id)
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
        typing_refusal(scope, channel_id)
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

  defdelegate thread_summaries_for_channel(scope, channel_id), to: Threads
  defdelegate get_thread_for_starter_message(scope, starter_message_id), to: Threads
  defdelegate get_thread(scope, thread_id), to: Threads

  defdelegate create_public_thread(scope, starter_message_id, attrs \\ %{}), to: Threads
  defdelegate archive_thread(scope, thread_id), to: Threads
  defdelegate unarchive_thread(scope, thread_id), to: Threads
  defdelegate lock_thread(scope, thread_id), to: Threads
  defdelegate unlock_thread(scope, thread_id), to: Threads

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
      Repo.transact(fn ->
        with :ok <- Visibility.authorize_write(scope, :send_messages, %Channel{id: channel_id}),
             {:ok, reopened} <- enforce_channel_state(scope, channel_id),
             :ok <- validate_reply_target(channel_id, attrs),
             :ok <- authorize_message_mentions(scope, channel_id, attrs),
             {:ok, message} <-
               %Message{channel_id: channel_id, author_id: scope.user_id}
               |> Message.create_changeset(attrs)
               |> Repo.insert(),
             :ok <- sync_message_mentions(message) do
          {:ok, {reload_message(message.id), reopened}}
        end
      end)
      |> case do
        {:ok, {message, reopened}} ->
          if reopened, do: Topics.broadcast_guild({:channel_updated, reopened})
          {:ok, message}

        {:error, reason} ->
          {:error, reason}
      end
      |> broadcast_written(:message_created)
    end
  end

  # Applies the two send rules that depend on the channel row: slowmode, and reopening an archived
  # thread. The row is read first without a lock, so a channel with neither costs no lock. A
  # channel with slowmode or an archived thread is locked `FOR UPDATE`, after the membership lock,
  # so two sends by one author queue behind each other and the second sees the first's message.
  # Returns `{:ok, reopened_thread_or_nil}`.
  defp enforce_channel_state(scope, channel_id) do
    case Repo.get(Channel, channel_id) do
      %Channel{slowmode_seconds: seconds, archived_at: archived_at}
      when seconds > 0 or not is_nil(archived_at) ->
        with %Channel{} = channel <- Channels.lock_channel(channel_id),
             :ok <- enforce_slowmode(scope, channel) do
          reopen_archived(channel)
        else
          nil -> {:error, :not_found}
          error -> error
        end

      _ ->
        {:ok, nil}
    end
  end

  defp enforce_slowmode(_scope, %Channel{slowmode_seconds: 0}), do: :ok

  defp enforce_slowmode(scope, %Channel{slowmode_seconds: seconds} = channel) do
    last_sent_at =
      Repo.one(
        from(message in Message,
          where: message.channel_id == ^channel.id and message.author_id == ^scope.user_id,
          select: max(message.inserted_at)
        )
      )

    left =
      if last_sent_at,
        do: seconds - DateTime.diff(DateTime.utc_now(), last_sent_at, :millisecond) / 1000,
        else: 0

    cond do
      left <= 0 -> :ok
      Visibility.can?(scope, :bypass_slowmode, channel) -> :ok
      true -> {:error, {:slowmode, ceil(left)}}
    end
  end

  defp reopen_archived(%Channel{archived_at: nil}), do: {:ok, nil}

  defp reopen_archived(%Channel{} = channel),
    do: channel |> Ecto.Changeset.change(archived_at: nil) |> Repo.update()

  @doc """
  The moderation cases against `subject_user_id`, newest first. A scope without `view_audit_log`
  gets `{:error, :forbidden}`.
  """
  def list_moderation_cases(%Scope{} = scope, subject_user_id) do
    if Visibility.can?(scope, :view_audit_log, :server) do
      with {:ok, subject_user_id} <- cast_id(subject_user_id) do
        cases =
          ModerationCase
          |> where([moderation_case], moderation_case.subject_user_id == ^subject_user_id)
          |> order_by([moderation_case], desc: moderation_case.inserted_at)
          |> preload([:actor_user, :subject_user])
          |> Repo.all()

        {:ok, cases}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Times out the member `subject_user_id` and records the case and the audit entry. Returns
  `{:ok, subject, moderation_case}`; see `moderate/4` for the refusals.
  """
  def timeout_member(%Scope{} = scope, subject_user_id, duration_minutes, reason \\ nil)
      when is_integer(duration_minutes) and duration_minutes > 0 do
    moderate(scope, subject_user_id, :moderate_members, fn membership, subject_id ->
      timeout_until = DateTime.add(DateTime.utc_now(), duration_minutes * 60, :second)

      membership = Repo.update!(Membership.timeout_changeset(membership, timeout_until))

      moderation_case =
        record_moderation_case(scope.user_id, subject_id, :timeout, reason,
          expires_at: timeout_until,
          executed_at: DateTime.utc_now(),
          details: %{"duration_minutes" => duration_minutes}
        )

      record_audit_log!(scope.user_id, subject_id, "timeout_member", reason, %{
        "duration_minutes" => duration_minutes,
        "timeout_until" => timeout_until
      })

      {membership, moderation_case}
    end)
  end

  @doc "Removes the member `subject_user_id` from the server. Returns `{:ok, subject, moderation_case}`."
  def kick_member(%Scope{} = scope, subject_user_id, reason \\ nil) do
    deactivate_member(scope, subject_user_id, :kick_members, :kick, reason, %{"kicked" => true})
  end

  @doc "Bans the member `subject_user_id`. Returns `{:ok, subject, moderation_case}`."
  def ban_member(%Scope{} = scope, subject_user_id, reason \\ nil) do
    deactivate_member(scope, subject_user_id, :ban_members, :ban, reason, %{
      "banned" => true,
      "ban_reason" => reason
    })
  end

  @doc """
  Edits a message the scope authored, and broadcasts it. A message the scope may not view is
  `{:error, :not_found}`. A visible message it may not edit (another author, or a timeout) is
  `{:error, :forbidden}`.
  """
  def update_message(%Scope{} = scope, message_id, attrs) do
    with {:ok, message_id} <- cast_id(message_id),
         {:ok, attrs} <- normalize_message_attrs(attrs) do
      Repo.transact(fn ->
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
      Repo.transact(fn ->
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
      Repo.transact(fn ->
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

  def can_create_public_threads?(channel, user),
    do: Visibility.can?(user_scope(user), :create_public_threads, channel)

  def can_send_messages_in_threads?(channel, user),
    do: Visibility.can?(user_scope(user), :send_messages_in_threads, channel)

  # The thread control the viewer would use now: archive when open, unarchive when archived.
  def can_archive_thread?(thread, user) do
    action = if thread.archived_at, do: :unarchive_thread, else: :archive_thread
    Visibility.can?(user_scope(user), action, thread)
  end

  def can_lock_thread?(thread, user) do
    action = if thread.locked_at, do: :unlock_thread, else: :lock_thread
    Visibility.can?(user_scope(user), action, thread)
  end

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

  # A removed member's sessions go after the removal commits, and their open LiveViews
  # disconnect. A socket that reconnects finds no session and is sent to log in.
  defp deactivate_member(scope, subject_user_id, bit, action_type, reason, extra_flags) do
    scope
    |> remove_membership(subject_user_id, bit, action_type, reason, extra_flags)
    |> tap(fn
      {:ok, subject, _moderation_case} -> Accounts.revoke_user_sessions(subject.id)
      {:error, _reason} -> :ok
    end)
  end

  defp remove_membership(scope, subject_user_id, bit, action_type, reason, extra_flags) do
    moderate(scope, subject_user_id, bit, fn membership, subject_id ->
      now = DateTime.utc_now()
      flags = Map.merge(membership.flags || %{}, extra_flags)

      membership =
        membership
        |> Membership.deactivate_changeset(now, flags)
        |> Repo.update!()

      moderation_case =
        record_moderation_case(scope.user_id, subject_id, action_type, reason,
          executed_at: now,
          details: flags
        )

      record_audit_log!(scope.user_id, subject_id, "#{action_type}_member", reason, flags)

      {membership, moderation_case}
    end)
  end

  # Every moderation write runs here, in one transaction. `Visibility.authorize_write/3` takes the
  # actor's and the subject's membership rows `FOR UPDATE` in user_id order, then decides, so the
  # decision sees the subject's state as of the lock. `change` gets the subject's membership row,
  # which that lock already holds, and returns the membership to keep and the moderation case. A
  # subject with no membership row is `:not_found`; a subject the actor may not moderate is
  # `:forbidden`, both from `Visibility`.
  defp moderate(%Scope{} = scope, subject_user_id, bit, change) do
    with {:ok, subject_user_id} <- cast_id(subject_user_id) do
      Repo.transact(fn ->
        with :ok <- Visibility.authorize_write(scope, {:moderate, bit}, subject_user_id),
             {:ok, membership} <- subject_membership(subject_user_id) do
          {membership, moderation_case} = change.(membership, subject_user_id)

          subject =
            User
            |> Repo.get!(subject_user_id)
            |> Repo.preload(member_roles: :role)
            |> Map.put(:membership, membership)

          {:ok, {subject, moderation_case}}
        end
      end)
      |> case do
        {:ok, {subject, moderation_case}} -> {:ok, subject, moderation_case}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp subject_membership(subject_id) do
    case Repo.get_by(Membership, user_id: subject_id) do
      nil -> {:error, :not_found}
      %Membership{} = membership -> {:ok, membership}
    end
  end

  defp record_moderation_case(actor_id, subject_id, action_type, reason, attrs) do
    attrs = %{
      action_type: action_type,
      state: :executed,
      actor_user_id: actor_id,
      subject_user_id: subject_id,
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

  defp record_audit_log!(actor_id, subject_id, action_type, reason, metadata) do
    %AuditLogEntry{}
    |> AuditLogEntry.changeset(%{
      action_type: action_type,
      actor_user_id: actor_id,
      subject_user_id: subject_id,
      target_type: "user",
      target_id: subject_id,
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

  # Decides a message write, then locks the message row and reads it. The lock keeps a moderator's
  # delete from committing between the decision and the change. The row is read again with its
  # deleted_at, so a message deleted after the decision is refused.
  defp authorize_message_write(scope, action, message_id) do
    with :ok <- Visibility.authorize_write(scope, action, %Message{id: message_id}) do
      case lock_live_message(message_id) do
        %Message{} = message -> {:ok, message}
        nil -> {:error, :not_found}
      end
    end
  end

  defp typing_refusal(scope, channel_id) do
    if Visibility.visible_channel(scope, channel_id),
      do: {:error, :forbidden},
      else: {:error, :not_found}
  end

  @doc false
  def lock_live_message(message_id) do
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
