defmodule Tavern.Bots do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Tavern.Accounts
  alias Tavern.Accounts.Scope
  alias Tavern.Bots.Authority
  alias Tavern.Bots.Commands
  alias Tavern.Bots.Serializer
  alias Tavern.Chat
  alias Tavern.Chat.AuditLogEntry
  alias Tavern.Chat.BotToken
  alias Tavern.Chat.Channel
  alias Tavern.Chat.MemberRole
  alias Tavern.Chat.Membership
  alias Tavern.Chat.Role
  alias Tavern.Chat.User
  alias Tavern.Chat.Visibility
  alias Tavern.Repo

  @touch_threshold_seconds 300

  def command_registry, do: Commands.command_registry()

  @doc "The bots the actor may control. Empty when the actor may not manage bots."
  def list_controllable_bot_users(%User{} = actor) do
    case Authority.manage_bots(actor) do
      {:ok, authority} ->
        bot_users_query()
        |> order_by([user], asc: user.display_name, asc: user.username)
        |> preload([:membership, :bot_tokens, member_roles: :role])
        |> Repo.all()
        |> Enum.filter(&(Authority.control_bot(authority, &1) == :ok))

      {:error, :forbidden} ->
        []
    end
  end

  def get_bot_user!(id) do
    bot_users_query()
    |> preload([:membership, :bot_tokens, member_roles: :role])
    |> Repo.get!(id)
  end

  @doc "The bot with `id`, or nil. A value that is not a UUID is not found, not an error."
  def get_bot_user(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        bot_users_query()
        |> preload([:membership, :bot_tokens, member_roles: :role])
        |> Repo.get(uuid)

      :error ->
        nil
    end
  end

  @doc """
  Creates a bot with the roles in `role_ids`. The actor must manage bots, and needs
  manage_roles plus authority over each role (see `Tavern.Bots.Authority`). Decides and writes
  in one transaction under the role-list lock (see `with_role_authority/2`).
  """
  def create_bot(attrs, %User{} = actor) when is_map(attrs) do
    role_ids = Map.get(attrs, "role_ids") || Map.get(attrs, :role_ids) || []

    with_role_authority(actor, fn authority ->
      with {:ok, roles} <- Authority.grant_roles(authority, role_ids) do
        {:ok, insert_bot!(attrs, roles, actor)}
      end
    end)
  end

  defp insert_bot!(attrs, roles, actor) do
    now = DateTime.utc_now()

    bot_user =
      %User{bot: true, system: false}
      |> User.account_changeset(%{
        username: Map.get(attrs, "username") || Map.get(attrs, :username),
        display_name: Map.get(attrs, "display_name") || Map.get(attrs, :display_name),
        email: Map.get(attrs, "email") || Map.get(attrs, :email),
        bio: Map.get(attrs, "bio") || Map.get(attrs, :bio)
      })
      |> Repo.insert!()

    membership =
      %Membership{user_id: bot_user.id}
      |> Membership.join_changeset(now)
      |> Repo.insert!()

    assign_roles!(bot_user, roles, actor)

    record_bot_audit_log!(actor, bot_user, "bot_created", %{"role_ids" => role_ids(roles)})

    bot_user
    |> Repo.preload([:membership, :bot_tokens, member_roles: :role])
    |> Map.put(:membership, membership)
  end

  @doc """
  Updates a bot's profile. When `attrs` carries `role_ids`, they replace the bot's roles under
  the same rules as `create_bot/2`; without it, the roles stay as they are.
  """
  def update_bot(%User{} = bot_user, attrs, %User{} = actor) when is_map(attrs) do
    with_role_authority(actor, fn authority ->
      with :ok <- Authority.control_bot(authority, bot_user),
           {:ok, roles} <- roles_for_update(authority, attrs) do
        {:ok, save_bot!(bot_user, attrs, roles, actor)}
      end
    end)
  end

  # A bot grant compares role positions, and a role write may renumber every position. So the
  # grant takes the role-list lock first, then the actor's membership row, then loads the actor's
  # authority, and decides and writes `member_roles` in that one transaction, as
  # `Tavern.Chat.Roles` does.
  defp with_role_authority(%User{} = actor, fun) do
    Repo.transact(fn ->
      Visibility.lock_role_list!()

      with :ok <- Visibility.authorize_write(%Scope{user_id: actor.id}, :manage_bots, :server),
           {:ok, authority} <- Authority.manage_bots(actor) do
        fun.(authority)
      end
    end)
  end

  defp roles_for_update(authority, attrs) do
    with :error <- Map.fetch(attrs, "role_ids"),
         :error <- Map.fetch(attrs, :role_ids) do
      {:ok, :keep}
    else
      {:ok, ids} -> Authority.grant_roles(authority, ids || [])
    end
  end

  defp save_bot!(bot_user, attrs, roles, actor) do
    updated_bot =
      bot_user
      |> User.account_changeset(%{
        username: Map.get(attrs, "username", bot_user.username),
        display_name: Map.get(attrs, "display_name", bot_user.display_name),
        email: Map.get(attrs, "email", bot_user.email),
        bio: Map.get(attrs, "bio", bot_user.bio)
      })
      |> Repo.update!()

    metadata =
      if roles == :keep do
        %{}
      else
        replace_roles!(updated_bot, roles, actor)
        %{"role_ids" => role_ids(roles)}
      end

    record_bot_audit_log!(actor, updated_bot, "bot_updated", metadata)
    Repo.preload(updated_bot, [:membership, :bot_tokens, member_roles: :role])
  end

  def revoke_bot(%User{} = bot_user, %User{} = actor) do
    with {:ok, authority} <- Authority.manage_bots(actor),
         :ok <- Authority.control_bot(authority, bot_user) do
      deactivate_bot(bot_user, actor)
    end
  end

  defp deactivate_bot(bot_user, actor) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      from(token in BotToken, where: token.user_id == ^bot_user.id)
      |> Repo.update_all(set: [revoked_at: now])

      if bot_user.membership do
        bot_user.membership
        |> Membership.deactivate_changeset(now, %{"bot_revoked" => true})
        |> Repo.update!()
      end

      revoked_bot =
        bot_user
        |> Ecto.Changeset.change(deleted_at: now)
        |> Repo.update!()

      record_bot_audit_log!(actor, revoked_bot, "bot_revoked", %{})
      Repo.preload(revoked_bot, [:membership, :bot_tokens, member_roles: :role])
    end)
    |> case do
      {:ok, revoked_bot} -> {:ok, revoked_bot}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def list_bot_tokens(%User{} = bot_user) do
    BotToken
    |> where([token], token.user_id == ^bot_user.id)
    |> order_by([token], desc: token.inserted_at)
    |> Repo.all()
  end

  @doc """
  The tokens of the bot `bot_id`, when the actor may control that bot. A missing bot and a bot
  the actor cannot control both return `{:error, :not_found}`, so the caller cannot tell them apart.
  """
  def list_controllable_bot_tokens(bot_id, %User{} = actor) do
    with %User{} = bot_user <- get_bot_user(bot_id),
         {:ok, authority} <- Authority.manage_bots(actor),
         :ok <- Authority.control_bot(authority, bot_user) do
      {:ok, list_bot_tokens(bot_user)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The token with `id`, or nil. A value that is not a UUID is not found, not an error."
  def get_bot_token(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(BotToken, uuid)
      :error -> nil
    end
  end

  @doc "Mints a token for the bot. The actor must have authority over the bot's roles."
  def create_bot_token(%User{} = bot_user, attrs, %User{} = actor) when is_map(attrs) do
    with {:ok, authority} <- Authority.manage_bots(actor),
         :ok <- Authority.control_bot(authority, bot_user) do
      insert_bot_token(bot_user, attrs, actor)
    end
  end

  defp insert_bot_token(bot_user, attrs, actor) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    with {:ok, expires_at} <- expires_at_from_attrs(attrs, now),
         {:ok, bot_token} <-
           %BotToken{}
           |> BotToken.changeset(%{
             user_id: bot_user.id,
             token_hash: Accounts.hash_token(token),
             label: Map.get(attrs, "label") || Map.get(attrs, :label),
             last_used_at: nil,
             expires_at: expires_at
           })
           |> Repo.insert() do
      record_bot_audit_log!(actor, bot_user, "bot_token_created", %{"token_id" => bot_token.id})
      {:ok, %{token: token, bot_token: bot_token}}
    end
  end

  @doc "Revokes `bot_token`. A token whose bot was deleted is `{:error, :not_found}`."
  def revoke_bot_token(%BotToken{} = bot_token, %User{} = actor) do
    with {:ok, authority} <- Authority.manage_bots(actor),
         {:ok, bot_user} <- fetch_bot_user(bot_token.user_id),
         :ok <- Authority.control_bot(authority, bot_user) do
      mark_token_revoked(bot_token, bot_user, actor)
    end
  end

  defp mark_token_revoked(bot_token, bot_user, actor) do
    now = DateTime.utc_now()

    case bot_token
         |> BotToken.changeset(%{revoked_at: now})
         |> Repo.update() do
      {:ok, revoked_token} ->
        record_bot_audit_log!(actor, bot_user, "bot_token_revoked", %{
          "token_id" => revoked_token.id
        })

        {:ok, revoked_token}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_bot_scope_by_token(token) when is_binary(token) do
    hashed_token = Accounts.hash_token(token)
    now = DateTime.utc_now()

    bot_token =
      BotToken
      |> join(:inner, [token], user in assoc(token, :user))
      |> where([token, user], token.token_hash == ^hashed_token)
      |> where([token, user], is_nil(token.revoked_at))
      |> where([token, user], is_nil(token.expires_at) or token.expires_at > ^now)
      |> where(
        [token, user],
        user.bot == true and user.system == false and is_nil(user.deleted_at)
      )
      |> Repo.one()

    # A valid token whose bot is deactivated cannot act, so it is refused here like any bad token.
    scope = bot_token && %Scope{user_id: bot_token.user_id, bot_token_id: bot_token.id}

    if scope && Visibility.member(scope) do
      touch_bot_token(bot_token)
      {:ok, scope}
    else
      {:error, :unauthorized}
    end
  end

  def can_manage_bots?(%Scope{} = scope), do: Visibility.can?(scope, :manage_bots, :server)

  def can_manage_bots?(_), do: false

  def execute_command(command_name, %Scope{} = scope, params) when is_map(params) do
    Commands.execute(command_name, scope, params)
  end

  def command_send_message(%Scope{} = scope, params), do: Commands.send_message(scope, params)

  def command_send_message(_, _), do: {:error, :invalid_params}

  def command_list_messages(%Scope{} = scope, params),
    do: Commands.list_messages(scope, params)

  def command_list_messages(_, _), do: {:error, :invalid_params}

  def get_thread_for_starter_message(%Scope{} = scope, starter_message_id) do
    case Ecto.UUID.cast(starter_message_id) do
      {:ok, starter_id} ->
        case Chat.get_thread_for_starter_message(scope, starter_id) do
          %Channel{} = thread -> {:ok, %{thread: Serializer.serialize_thread(thread)}}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def get_thread_for_starter_message(_, _), do: {:error, :invalid_params}

  def create_public_thread(scope, starter_message_id, attrs \\ %{})

  def create_public_thread(%Scope{} = scope, starter_message_id, attrs) when is_map(attrs) do
    with {:ok, _bot_user} <- acting_member(scope) do
      case Chat.create_public_thread(scope, starter_message_id, attrs) do
        {:ok, thread} -> {:ok, %{thread: Serializer.serialize_thread(thread)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_public_thread(_, _, _), do: {:error, :invalid_params}

  def command_timeout_member(%Scope{} = scope, params),
    do: Commands.timeout_member(scope, params)

  def command_timeout_member(_, _), do: {:error, :invalid_params}

  def command_kick_member(%Scope{} = scope, params), do: Commands.kick_member(scope, params)

  def command_kick_member(_, _), do: {:error, :invalid_params}

  def command_ban_member(%Scope{} = scope, params), do: Commands.ban_member(scope, params)

  def command_ban_member(_, _), do: {:error, :invalid_params}

  @doc """
  The member a bot scope acts as, for the context calls that still take a `%User{}`. A revoked
  or expired token yields `{:error, :unauthorized}`.
  """
  def acting_member(%Scope{} = scope) do
    case Visibility.member(scope) do
      %User{} = bot_user -> {:ok, bot_user}
      nil -> {:error, :unauthorized}
    end
  end

  def serialize_bot_user(%User{} = bot_user), do: Serializer.serialize_bot_user(bot_user)

  def serialize_message(message), do: Serializer.serialize_message(message)

  def serialize_thread(thread), do: Serializer.serialize_thread(thread)

  defp fetch_bot_user(user_id) do
    case get_bot_user(user_id) do
      nil -> {:error, :not_found}
      bot_user -> {:ok, bot_user}
    end
  end

  @doc "Every role the actor may give a bot; empty when the actor may not manage bots."
  def grantable_roles(%User{} = actor) do
    case Authority.manage_bots(actor) do
      {:ok, authority} -> Authority.grantable_roles(authority)
      {:error, :forbidden} -> []
    end
  end

  defp assign_roles!(%User{} = bot_user, roles, %User{} = actor) do
    Enum.each(roles, fn %Role{id: role_id} ->
      %MemberRole{}
      |> MemberRole.changeset(%{
        user_id: bot_user.id,
        role_id: role_id,
        granted_by_user_id: actor.id
      })
      |> Repo.insert!()
    end)
  end

  defp replace_roles!(%User{} = bot_user, roles, %User{} = actor) do
    from(member_role in MemberRole, where: member_role.user_id == ^bot_user.id)
    |> Repo.delete_all()

    assign_roles!(bot_user, roles, actor)
  end

  defp role_ids(roles), do: Enum.map(roles, & &1.id)

  defp touch_bot_token(%BotToken{id: id}) do
    threshold = DateTime.add(DateTime.utc_now(), -@touch_threshold_seconds, :second)

    from(token in BotToken,
      where: token.id == ^id,
      where: is_nil(token.last_used_at) or token.last_used_at < ^threshold
    )
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])
  end

  defp record_bot_audit_log!(%User{} = actor, %User{} = bot_user, action_type, metadata) do
    %AuditLogEntry{}
    |> AuditLogEntry.changeset(%{
      action_type: action_type,
      actor_user_id: actor.id,
      subject_user_id: bot_user.id,
      target_type: "bot",
      target_id: bot_user.id,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  # Only the `expires_in_days` key is read. Absent or blank means the token never expires.
  # Ecto's integer cast accepts a JSON integer and a form string such as "30"; the settings
  # form posts "" when the field is left blank. Any other value is a changeset error, so a
  # bad value can never mint a token that does not expire.
  defp expires_at_from_attrs(attrs, now) do
    {%{}, %{expires_in_days: :integer}}
    |> Ecto.Changeset.cast(Map.take(attrs, ["expires_in_days"]), [:expires_in_days])
    |> Ecto.Changeset.validate_number(:expires_in_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 365
    )
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, data} ->
        case Map.get(data, :expires_in_days) do
          nil -> {:ok, nil}
          days -> {:ok, DateTime.add(now, days * 86_400, :second)}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Bootstrap creates the system user with bot: true, but it is the server's own actor: no
  # member may list it, manage it or hold a token for it.
  defp bot_users_query do
    where(User, [user], user.bot == true and user.system == false and is_nil(user.deleted_at))
  end
end
