defmodule Rfchat.Chat.Visibility do
  @moduledoc """
  Makes every access decision in the chat, for a `%Rfchat.Accounts.Scope{}`.

  A decision loads its inputs in one statement: the account with membership and roles, the
  default role, and for a channel or message target the channel, its parent and their overwrites.
  It then decides with the pure functions in this module and `Rfchat.Chat.Authorization`. Nothing
  is cached between calls, so a role, timeout or ban change applies to the next decision.

  A bot scope names a token. Every load first checks that the token row still names the bot,
  is not revoked and has not expired; a failed check leaves the scope with no account.

  The account is the user row with its membership, whatever the membership's state. The
  member is the account when the membership is active. A decision about who may act uses the
  member. A moderation decision reads the subject's account, so a kicked member can still be
  banned: a deactivated membership removes the right to act, not the rank that others are measured
  against.
  """

  import Ecto.Query, warn: false

  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.BotToken
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.ChannelPermissionOverwrite
  alias Rfchat.Chat.MemberRole
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  # A UUID that names no message. Loads that have no message target join against it, so the
  # message join matches nothing.
  @no_message_id "00000000-0000-0000-0000-000000000000"

  @doc "The member the scope acts as, with membership and roles, or nil when none may act."
  def member(%Scope{} = scope) do
    scope |> load([]) |> Map.fetch!(:member)
  end

  @doc """
  Whether a membership's timeout is still running. A timed-out member may view but not send,
  react, or create threads.
  """
  def timed_out?(%Membership{timeout_until: nil}), do: false

  def timed_out?(%Membership{timeout_until: timeout_until}),
    do: DateTime.compare(timeout_until, DateTime.utc_now()) == :gt

  @doc """
  Whether the scope may do `action` on `target` now.

  Channel bits take a `%Channel{}` target. Server-wide bits take `:server`. `:send_messages`,
  `:send_messages_in_threads` and the rest of the timed actions check the member's timeout
  first. `:edit_message`, `:delete_message` and `:add_reactions` take a `%Message{}` and read
  only its id: the message and its channel load in the decision's own statement. `{:moderate,
  bit}` takes the subject's user id.
  """
  def can?(%Scope{} = scope, action, target) do
    ctx = load_for(scope, action, target)

    if is_nil(ctx.member), do: false, else: decide(action, ctx, target)
  end

  @doc """
  `can?/3` for a write. Runs inside a transaction, and first takes the scope's membership row
  `FOR SHARE`, so a timeout, ban or role change that commits before the write is seen by the
  decision, and one that tries to commit during the write waits for it to finish.

  Raises outside a transaction, because the lock is released when the transaction ends and
  a lock taken outside one would protect nothing.
  """
  def lock_and_can?(%Scope{user_id: user_id} = scope, action, target) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "lock_and_can?/3 must run inside a transaction"
    end

    from(membership in Membership,
      where: membership.user_id == ^user_id,
      select: membership.id,
      lock: "FOR SHARE"
    )
    |> Repo.one()

    can?(scope, action, target)
  end

  @doc """
  The channels and threads the scope may view now, ordered by position then creation. Each is
  the struct as loaded, with its overwrites.
  """
  def visible_channels(%Scope{} = scope) do
    ctx = load(scope, [])

    if is_nil(ctx.member) do
      []
    else
      channels =
        Repo.all(
          from(channel in Channel,
            order_by: [asc: channel.position, asc: channel.inserted_at],
            preload: [:permission_overwrites]
          )
        )

      ctx = %{ctx | channels: Map.new(channels, &{&1.id, &1})}
      Enum.filter(channels, &view?(ctx, &1))
    end
  end

  @doc "The ids of `visible_channels/1`, in the same order."
  def channel_ids(%Scope{} = scope) do
    scope
    |> visible_channels()
    |> Enum.map(& &1.id)
  end

  @doc """
  The channel `channel_id` when the scope may view it now, as the decision loaded it, or nil. A
  read that returns rows of this channel sets their `channel` from it, so it costs no query.
  """
  def visible_channel(%Scope{} = scope, channel_id) do
    ctx = load(scope, [channel_id])

    with false <- is_nil(ctx.member),
         {:ok, channel} <- Map.fetch(ctx.channels, channel_id),
         true <- view?(ctx, channel) do
      channel
    else
      _ -> nil
    end
  end

  @doc """
  The message `message_id` with its `channel` set, when the scope may view its channel now, or nil.
  The message and its channel come from the decision's own statement, so a read that returns the
  message decided on the same snapshot the message was read from.
  """
  def visible_message(%Scope{} = scope, message_id) do
    ctx = load(scope, [], message_id)

    with false <- is_nil(ctx.member),
         %Message{channel_id: channel_id} = message <- ctx.message,
         {:ok, channel} <- Map.fetch(ctx.channels, channel_id),
         true <- view?(ctx, channel) do
      %{message | channel: channel}
    else
      _ -> nil
    end
  end

  @doc """
  The facts `Rfchat.Bots.Authority` decides from, read in one load: whether the scope is the
  owner, its server bits (owner and administrator expanded), its highest role position, and its
  bits in each of `channel_ids`. A scope with no member holds nothing.
  """
  def authority(%Scope{} = scope, channel_ids) do
    ctx = load(scope, channel_ids)

    case ctx.member do
      nil ->
        %{owner?: false, server_permissions: 0, top_role_position: 0, channel_permissions: %{}}

      member ->
        %{
          owner?: owner?(member),
          server_permissions: server_bits(ctx),
          top_role_position: top_position(member, ctx.default_role),
          channel_permissions: Map.new(channel_ids, &{&1, channel_bits(ctx, &1)})
        }
    end
  end

  # --- Loading ---------------------------------------------------------------------------------

  # Loads the account, the member, the default role, the channels named by `channel_ids` with
  # their parents and overwrites, and the message named by `message_id`, in one statement.
  defp load(scope, channel_ids), do: load(scope, channel_ids, @no_message_id)

  defp load(%Scope{user_id: user_id, bot_token_id: token_id}, channel_ids, message_id) do
    now = DateTime.utc_now()
    base = from(user in User, where: user.id == ^user_id and is_nil(user.deleted_at))

    base =
      if is_nil(token_id) do
        base
      else
        from(user in base,
          join: token in BotToken,
          on:
            token.user_id == user.id and token.id == ^token_id and is_nil(token.revoked_at) and
              (is_nil(token.expires_at) or token.expires_at > ^now)
        )
      end

    base
    |> join_inputs(channel_ids, message_id)
    |> Repo.all()
    |> assemble()
  end

  defp load_for(%Scope{} = scope, _action, %Message{id: message_id}),
    do: load(scope, [], message_id)

  defp load_for(%Scope{} = scope, _action, %Channel{id: channel_id}),
    do: load(scope, [channel_id])

  defp load_for(%Scope{} = scope, _action, _target), do: load(scope, [])

  defp join_inputs(base, channel_ids, message_id) do
    from(user in base,
      left_join: membership in assoc(user, :membership),
      left_join: member_role in MemberRole,
      on: member_role.user_id == user.id,
      left_join: role in Role,
      on: role.id == member_role.role_id,
      left_join: default_role in Role,
      on: default_role.is_default == true,
      left_join: target in Message,
      on: target.id == ^message_id,
      left_join: channel in Channel,
      on: channel.id in ^channel_ids or channel.id == target.channel_id,
      left_join: parent in Channel,
      on: parent.id == channel.parent_channel_id,
      left_join: channel_overwrite in ChannelPermissionOverwrite,
      on: channel_overwrite.channel_id == channel.id,
      left_join: parent_overwrite in ChannelPermissionOverwrite,
      on: parent_overwrite.channel_id == parent.id,
      select:
        {user, membership, member_role, role, default_role, target, channel, channel_overwrite,
         parent, parent_overwrite}
    )
  end

  # The joined rows repeat the account once per role and overwrite. This folds them back into one
  # account with its roles, one default role, the target message, and each loaded channel with
  # its overwrites.
  defp assemble([]),
    do: %{account: nil, member: nil, default_role: nil, message: nil, channels: %{}}

  defp assemble([{user, _, _, _, _, _, _, _, _, _} | _] = rows) do
    membership =
      rows |> Enum.find_value(fn {_, membership, _, _, _, _, _, _, _, _} -> membership end)

    member_roles =
      rows
      |> Enum.flat_map(fn {_, _, member_role, role, _, _, _, _, _, _} ->
        if member_role, do: [%{member_role | role: role}], else: []
      end)
      |> Enum.uniq_by(& &1.id)

    default_role =
      Enum.find_value(rows, fn {_, _, _, _, default_role, _, _, _, _, _} -> default_role end)

    message = Enum.find_value(rows, fn {_, _, _, _, _, target, _, _, _, _} -> target end)

    account = if membership, do: %{user | membership: membership, member_roles: member_roles}

    member = if membership && is_nil(membership.deactivated_at), do: account

    channels =
      rows
      |> Enum.reduce(%{}, fn {_, _, _, _, _, _, channel, channel_overwrite, parent,
                              parent_overwrite},
                             acc ->
        acc
        |> add_channel(channel, channel_overwrite)
        |> add_channel(parent, parent_overwrite)
      end)
      |> Map.new(fn {id, {channel, overwrites}} ->
        {id, %{channel | permission_overwrites: Map.values(overwrites)}}
      end)

    %{
      account: account,
      member: member,
      default_role: default_role,
      message: message,
      channels: channels
    }
  end

  defp add_channel(acc, nil, _overwrite), do: acc

  defp add_channel(acc, %Channel{id: id} = channel, overwrite) do
    {_, overwrites} = Map.get(acc, id, {channel, %{}})

    overwrites =
      if overwrite, do: Map.put(overwrites, overwrite.id, overwrite), else: overwrites

    Map.put(acc, id, {channel, overwrites})
  end

  # --- Decisions -------------------------------------------------------------------------------

  defp decide(action, ctx, %Channel{id: channel_id}) when is_atom(action) do
    case Map.fetch(ctx.channels, channel_id) do
      {:ok, channel} -> channel_decision(action, ctx, channel)
      :error -> false
    end
  end

  # A deleted message takes no action, so edit, delete and reaction answer as for a missing one.
  defp decide(action, ctx, %Message{}) when is_atom(action) do
    with %Message{deleted_at: nil, author_id: author_id, channel_id: channel_id} <- ctx.message,
         {:ok, channel} <- Map.fetch(ctx.channels, channel_id) do
      message_decision(action, ctx, author_id, channel)
    else
      _ -> false
    end
  end

  defp decide(action, ctx, :server) when is_atom(action) do
    Authorization.has_permission?(server_bits(ctx), action)
  end

  defp decide({:moderate, bit}, ctx, subject_id) when is_binary(subject_id) do
    subject = load(%Scope{user_id: subject_id}, [])

    cond do
      is_nil(subject.account) ->
        false

      ctx.member.id == subject_id ->
        false

      owner?(subject.account) ->
        false

      not moderation_bit?(ctx, bit) ->
        false

      owner?(ctx.member) ->
        true

      true ->
        top_position(ctx.member, ctx.default_role) >
          top_position(subject.account, subject.default_role)
    end
  end

  defp message_decision(:edit_message, ctx, author_id, channel),
    do: ctx.member.id == author_id and not acting_timed_out?(ctx) and view?(ctx, channel)

  defp message_decision(:delete_message, ctx, author_id, channel),
    do:
      view?(ctx, channel) and
        (ctx.member.id == author_id or bit?(ctx, channel, :manage_messages))

  defp message_decision(:add_reactions, ctx, _author_id, channel),
    do: channel_decision(:add_reactions, ctx, channel)

  defp channel_decision(:view_channel, ctx, channel), do: view?(ctx, channel)
  defp channel_decision(:send_messages, ctx, channel), do: send?(ctx, channel)

  defp channel_decision(:send_messages_in_threads, ctx, channel),
    do: send_in_thread?(ctx, channel)

  defp channel_decision(:create_public_threads, ctx, channel), do: create_threads?(ctx, channel)

  defp channel_decision(:add_reactions, ctx, channel),
    do: not acting_timed_out?(ctx) and view?(ctx, channel) and bit?(ctx, channel, :add_reactions)

  defp channel_decision(:manage_messages, ctx, channel),
    do: view?(ctx, channel) and bit?(ctx, channel, :manage_messages)

  defp channel_decision(:mention_everyone, ctx, channel),
    do: view?(ctx, channel) and bit?(ctx, channel, :mention_everyone)

  # A thread is visible when its parent is visible and the thread itself grants view.
  defp view?(ctx, %Channel{} = channel) do
    if Channel.thread?(channel) do
      parent_visible?(ctx, channel) and bit?(ctx, channel, :view_channel)
    else
      bit?(ctx, channel, :view_channel)
    end
  end

  defp parent_visible?(ctx, channel) do
    case parent(ctx, channel) do
      nil -> false
      parent -> view?(ctx, parent)
    end
  end

  defp send?(ctx, %Channel{} = channel) do
    if Channel.thread?(channel) do
      send_in_thread?(ctx, channel)
    else
      not acting_timed_out?(ctx) and bit?(ctx, channel, :send_messages) and view?(ctx, channel)
    end
  end

  defp send_in_thread?(ctx, %Channel{} = thread) do
    Channel.thread?(thread) and not acting_timed_out?(ctx) and view?(ctx, thread) and
      bit?(ctx, thread, :send_messages_in_threads) and
      case parent(ctx, thread) do
        nil -> false
        parent -> send?(ctx, parent)
      end
  end

  defp create_threads?(ctx, %Channel{} = channel) do
    Channel.thread_host?(channel) and not acting_timed_out?(ctx) and send?(ctx, channel) and
      bit?(ctx, channel, :create_public_threads)
  end

  defp parent(_ctx, %Channel{parent_channel_id: nil}), do: nil
  defp parent(ctx, %Channel{parent_channel_id: parent_id}), do: Map.get(ctx.channels, parent_id)

  defp bit?(ctx, %Channel{} = channel, bit) do
    channel_bits(ctx, channel)
    |> Authorization.has_permission?(bit)
  end

  defp channel_bits(ctx, %Channel{} = channel) do
    Authorization.channel_permissions(ctx.member, channel, ctx.default_role)
  end

  defp channel_bits(ctx, channel_id) when is_binary(channel_id) do
    case Map.fetch(ctx.channels, channel_id) do
      {:ok, channel} -> channel_bits(ctx, channel)
      :error -> 0
    end
  end

  defp server_bits(ctx), do: Authorization.server_permissions(ctx.member, ctx.default_role)

  defp moderation_bit?(ctx, bit) do
    permissions = server_bits(ctx)

    Authorization.has_permission?(permissions, bit) or
      Authorization.has_permission?(permissions, :administrator)
  end

  defp acting_timed_out?(ctx), do: timed_out?(ctx.member.membership)

  defp owner?(%User{membership: %Membership{is_owner: true}}), do: true
  defp owner?(_account), do: false

  defp top_position(%User{member_roles: member_roles}, default_role) do
    member_roles
    |> Enum.map(& &1.role.position)
    |> Enum.max(fn -> (default_role && default_role.position) || 0 end)
  end
end
