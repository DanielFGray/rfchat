defmodule Rfchat.Bots do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Accounts
  alias Rfchat.Accounts.Scope
  alias Rfchat.Bots.Commands
  alias Rfchat.Bots.Serializer
  alias Rfchat.Chat
  alias Rfchat.Chat.AuditLogEntry
  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.BotToken
  alias Rfchat.Chat.MemberRole
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  @touch_threshold_seconds 300

  defmodule BotScope do
    @moduledoc false

    defstruct [:bot_user, :token, roles: [], base_permissions: 0]
  end

  def command_registry, do: Commands.command_registry()

  def list_bot_users do
    User
    |> where([user], user.bot == true and is_nil(user.deleted_at))
    |> order_by([user], asc: user.display_name, asc: user.username)
    |> preload([:membership, :bot_tokens, member_roles: :role])
    |> Repo.all()
  end

  def get_bot_user!(id) do
    User
    |> where([user], user.bot == true and is_nil(user.deleted_at))
    |> preload([:membership, :bot_tokens, member_roles: :role])
    |> Repo.get!(id)
  end

  def get_bot_user(id) do
    User
    |> where([user], user.bot == true and is_nil(user.deleted_at))
    |> preload([:membership, :bot_tokens, member_roles: :role])
    |> Repo.get(id)
  end

  def create_bot(attrs, %User{} = actor) when is_map(attrs) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      bot_user =
        %User{bot: true, system: false}
        |> User.changeset(%{
          username: Map.get(attrs, "username") || Map.get(attrs, :username),
          display_name: Map.get(attrs, "display_name") || Map.get(attrs, :display_name),
          email: Map.get(attrs, "email") || Map.get(attrs, :email),
          bio: Map.get(attrs, "bio") || Map.get(attrs, :bio)
        })
        |> Repo.insert!()

      membership =
        %Membership{user_id: bot_user.id}
        |> Membership.changeset(%{joined_at: now, is_owner: false})
        |> Repo.insert!()

      role_ids = Map.get(attrs, "role_ids") || Map.get(attrs, :role_ids) || []
      assign_roles!(bot_user, role_ids, actor)

      record_bot_audit_log!(actor, bot_user, "bot_created", %{"role_ids" => role_ids})

      bot_user
      |> Repo.preload([:membership, :bot_tokens, member_roles: :role])
      |> Map.put(:membership, membership)
    end)
    |> case do
      {:ok, bot_user} -> {:ok, bot_user}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def update_bot(%User{} = bot_user, attrs, %User{} = actor) when is_map(attrs) do
    Repo.transaction(fn ->
      updated_bot =
        bot_user
        |> User.changeset(%{
          username: Map.get(attrs, "username", bot_user.username),
          display_name: Map.get(attrs, "display_name", bot_user.display_name),
          email: Map.get(attrs, "email", bot_user.email),
          bio: Map.get(attrs, "bio", bot_user.bio)
        })
        |> Repo.update!()

      role_ids = Map.get(attrs, "role_ids") || Map.get(attrs, :role_ids) || []
      replace_roles!(updated_bot, role_ids, actor)

      record_bot_audit_log!(actor, updated_bot, "bot_updated", %{"role_ids" => role_ids})
      Repo.preload(updated_bot, [:membership, :bot_tokens, member_roles: :role])
    end)
    |> case do
      {:ok, updated_bot} -> {:ok, updated_bot}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def revoke_bot(%User{} = bot_user, %User{} = actor) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      from(token in BotToken, where: token.user_id == ^bot_user.id)
      |> Repo.update_all(set: [revoked_at: now])

      if bot_user.membership do
        bot_user.membership
        |> Membership.changeset(%{deactivated_at: now, flags: %{"bot_revoked" => true}})
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

  def create_bot_token(%User{} = bot_user, attrs, %User{} = actor) when is_map(attrs) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    expires_at =
      case parse_optional_days(
             Map.get(attrs, "expires_in_days") || Map.get(attrs, :expires_in_days)
           ) do
        {:ok, days} -> DateTime.add(now, days * 86_400, :second)
        :none -> nil
        :error -> nil
      end

    case %BotToken{}
         |> BotToken.changeset(%{
           user_id: bot_user.id,
           token_hash: Accounts.hash_token(token),
           label: Map.get(attrs, "label") || Map.get(attrs, :label),
           last_used_at: nil,
           expires_at: expires_at
         })
         |> Repo.insert() do
      {:ok, bot_token} ->
        record_bot_audit_log!(actor, bot_user, "bot_token_created", %{"token_id" => bot_token.id})
        {:ok, %{token: token, bot_token: bot_token}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def revoke_bot_token(%BotToken{} = bot_token, %User{} = actor) do
    now = DateTime.utc_now()

    case bot_token
         |> BotToken.changeset(%{revoked_at: now})
         |> Repo.update() do
      {:ok, revoked_token} ->
        record_bot_audit_log!(actor, get_bot_user!(revoked_token.user_id), "bot_token_revoked", %{
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
      |> where([token, user], user.bot == true and is_nil(user.deleted_at))
      |> preload([token, user], user: [:membership, member_roles: :role])
      |> Repo.one()

    if bot_token do
      touch_bot_token(bot_token)

      {:ok,
       %BotScope{
         bot_user: bot_token.user,
         token: bot_token,
         roles: Enum.map(bot_token.user.member_roles || [], & &1.role),
         base_permissions: Authorization.base_permissions(bot_token.user, Chat.default_role())
       }}
    else
      {:error, :unauthorized}
    end
  end

  def can_manage_bots?(%Scope{} = scope) do
    permissions = scope.base_permissions || 0

    Authorization.has_permission?(permissions, :manage_bots) or
      Authorization.has_permission?(permissions, :administrator) or
      (scope.membership && scope.membership.is_owner)
  end

  def can_manage_bots?(_), do: false

  def execute_command(command_name, %BotScope{} = scope, params) when is_map(params) do
    Commands.execute(command_name, scope, params)
  end

  def command_send_message(
        %BotScope{} = scope,
        params
      ) do
    Commands.send_message(scope, params)
  end

  def command_send_message(_, _), do: {:error, :invalid_params}

  def command_list_messages(%BotScope{} = scope, params),
    do: Commands.list_messages(scope, params)

  def command_list_messages(_, _), do: {:error, :invalid_params}

  def command_timeout_member(%BotScope{} = scope, params),
    do: Commands.timeout_member(scope, params)

  def command_timeout_member(_, _), do: {:error, :invalid_params}

  def command_kick_member(%BotScope{} = scope, params), do: Commands.kick_member(scope, params)

  def command_kick_member(_, _), do: {:error, :invalid_params}

  def command_ban_member(%BotScope{} = scope, params), do: Commands.ban_member(scope, params)

  def command_ban_member(_, _), do: {:error, :invalid_params}

  def serialize_bot_user(%User{} = bot_user), do: Serializer.serialize_bot_user(bot_user)

  def serialize_message(message), do: Serializer.serialize_message(message)

  defp assign_roles!(%User{} = bot_user, role_ids, %User{} = actor) do
    role_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn role_id ->
      %MemberRole{}
      |> MemberRole.changeset(%{
        user_id: bot_user.id,
        role_id: role_id,
        granted_by_user_id: actor.id
      })
      |> Repo.insert!()
    end)
  end

  defp replace_roles!(%User{} = bot_user, role_ids, %User{} = actor) do
    from(member_role in MemberRole, where: member_role.user_id == ^bot_user.id)
    |> Repo.delete_all()

    assign_roles!(bot_user, role_ids, actor)
  end

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

  defp parse_optional_days(nil), do: :none
  defp parse_optional_days(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_optional_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_optional_days(_), do: :error
end
