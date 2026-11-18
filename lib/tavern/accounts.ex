defmodule Tavern.Accounts do
  @moduledoc """
  Authentication and account management for tavern users.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tavern.Accounts.Scope
  alias Tavern.Chat.BotToken
  alias Tavern.Chat.Membership
  alias Tavern.Chat.User
  alias Tavern.Chat.UserSession
  alias Tavern.Chat.Visibility
  alias Tavern.Ephemeral
  alias Tavern.Repo

  @session_valid_days 30
  # An arbitrary constant that names "server ownership" among Postgres advisory locks.
  @ownership_lock_key 7_314_002_001

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  The active members of the server (not deleted, not deactivated), owners first, each with its
  presence. A scope that is not an active member gets `[]`.
  """
  def list_members(%Scope{} = scope) do
    if is_nil(Visibility.member(scope)),
      do: [],
      else: presence_entries(Repo.all(preload(active_members(), [:membership])))
  end

  @doc """
  The active member `user_id` with its membership and roles, or nil. A scope that is not an active
  member gets nil, and so does a banned, removed or deleted user, or an id that is not a UUID.
  """
  def get_member(%Scope{} = scope, user_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %User{} <- Visibility.member(scope) do
      active_members()
      |> where([user], user.id == ^user_id)
      |> preload([:membership, member_roles: :role])
      |> Repo.one()
    else
      _ -> nil
    end
  end

  defp active_members do
    User
    |> join(:inner, [user], membership in Membership, on: membership.user_id == user.id)
    |> where([user, membership], is_nil(user.deleted_at) and is_nil(membership.deactivated_at))
    |> order_by([_user, membership], desc: membership.is_owner, asc: membership.joined_at)
  end

  defp presence_entries(members) do
    now = DateTime.utc_now()

    active_sessions =
      members
      |> Enum.map(& &1.id)
      |> Ephemeral.get_presence_timestamps()

    Enum.map(members, fn user ->
      last_active_at =
        active_sessions[user.id] || user.membership.last_seen_at || user.inserted_at

      status = presence_status(last_active_at, now)

      %{user: user, last_active_at: last_active_at, status: status}
    end)
  end

  def get_user_by_session_token(token) when is_binary(token) do
    hashed_token = hash_token(token)
    now = DateTime.utc_now()

    user =
      User
      |> join(:inner, [user], session in UserSession, on: session.user_id == user.id)
      |> where([_user, session], session.context == "session")
      |> where([_user, session], session.token_hash == ^hashed_token)
      |> where([_user, session], is_nil(session.revoked_at) and session.expires_at > ^now)
      |> preload([user, _session], [:membership, member_roles: :role])
      |> Repo.one()

    if user do
      touch_session(token)
      heartbeat_presence(user)
    end

    user
  end

  def register_user(attrs) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      user =
        %User{}
        |> User.registration_changeset(attrs)
        |> Repo.insert!()

      membership = create_membership!(user, now)

      user
      |> Repo.preload([:membership, member_roles: :role])
      |> Map.put(:membership, membership)
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, _op, %Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, _op, reason, _changes} -> raise reason
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  @doc """
  Promote an existing active human member to the first server owner.

  The ownership lock makes the check and promotion one decision across concurrent release
  commands. Existing owners remain owners; transfers use `promote_to_owner/2` instead.
  """
  def promote_first_owner(email) when is_binary(email) do
    Repo.transaction(fn ->
      lock_ownership!()

      cond do
        owner_exists?() ->
          Repo.rollback(:owner_exists)

        true ->
          case Repo.one(
                 from user in User,
                   join: membership in Membership,
                   on: membership.user_id == user.id,
                   where:
                     user.email == ^String.downcase(email) and is_nil(user.deleted_at) and
                       user.bot == false and is_nil(membership.deactivated_at),
                   select: {user, membership}
               ) do
            {user, membership} ->
              updated_membership =
                membership
                |> Membership.ownership_changeset(true)
                |> Repo.update!()

              user
              |> Repo.preload([:membership, member_roles: :role])
              |> Map.put(:membership, updated_membership)

            nil ->
              Repo.rollback(:not_found)
          end
      end
    end)
  end

  def register_user!(attrs) do
    case register_user(attrs) do
      {:ok, user} ->
        user

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  def change_registration_user(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end

  def change_profile_user(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  def update_profile_user(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_user} ->
        {:ok, Repo.preload(updated_user, [:membership, member_roles: :role])}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def change_user_email(%User{} = user, attrs \\ %{}) do
    User.email_changeset(user, attrs)
  end

  @doc """
  Changes the email when `password` is the account's current password. A wrong or missing
  password adds an error on `:password` and writes nothing.
  """
  def update_user_email(%User{} = user, password, attrs) do
    changeset = User.email_changeset(user, attrs)

    if valid_user_password?(user, password) do
      changeset
      |> Repo.update()
      |> case do
        {:ok, updated_user} ->
          {:ok, Repo.preload(updated_user, [:membership, member_roles: :role])}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      changeset
      |> Ecto.Changeset.add_error(:password, "is not correct")
      |> Ecto.Changeset.apply_action(:update)
    end
  end

  def dummy_login_changeset do
    User.login_changeset(%User{}, %{})
  end

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(String.downcase(email))

    if valid_user_password?(user, password),
      do: Repo.preload(user, [:membership, member_roles: :role])
  end

  def valid_user_password?(%User{hashed_password: nil}, _password) do
    Bcrypt.no_user_verify()
    false
  end

  def valid_user_password?(%User{} = user, password) when is_binary(password) do
    Bcrypt.verify_pass(password, user.hashed_password)
  end

  def valid_user_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  def generate_user_session_token(%User{} = user, attrs \\ %{}) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    %UserSession{}
    |> UserSession.session_changeset(%{
      user_id: user.id,
      token_hash: hash_token(token),
      context: "session",
      expires_at: DateTime.add(now, @session_valid_days * 86_400, :second),
      last_seen_at: now,
      user_agent: Map.get(attrs, :user_agent),
      ip_address: Map.get(attrs, :ip_address)
    })
    |> Repo.insert!()

    token
  end

  def delete_user_session_token(token) when is_binary(token) do
    hashed_token = hash_token(token)
    now = DateTime.utc_now()

    from(session in UserSession,
      where: session.token_hash == ^hashed_token and session.context == "session"
    )
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  @doc """
  The id of the socket topic a session's LiveViews join, derived from the stored token hash so
  the server can find the sockets of any session row. A `"disconnect"` broadcast to it closes them.
  """
  def live_socket_id(token) when is_binary(token), do: socket_id_for_hash(hash_token(token))

  @doc """
  Deletes every session of `user_id` and disconnects their open LiveViews. Run it after the
  transaction that removed the member has committed, so a reconnecting socket finds no session.
  """
  def revoke_user_sessions(user_id) do
    {_count, hashes} =
      from(session in UserSession,
        where: session.user_id == ^user_id and session.context == "session",
        select: session.token_hash
      )
      |> Repo.delete_all()

    Enum.each(hashes, fn hash ->
      TavernWeb.Endpoint.broadcast(socket_id_for_hash(hash), "disconnect", %{})
    end)

    :ok
  end

  defp socket_id_for_hash(hash), do: "users_sessions:" <> Base.url_encode64(hash, padding: false)

  def delete_bot_token(token) when is_binary(token) do
    hashed_token = hash_token(token)
    now = DateTime.utc_now()

    from(bot_token in BotToken, where: bot_token.token_hash == ^hashed_token)
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  def user_scope(%User{id: user_id}), do: %Scope{user_id: user_id}

  def membership_state(nil), do: :anonymous

  def membership_state(%User{membership: nil}), do: :removed

  def membership_state(%User{membership: membership}) do
    cond do
      is_nil(membership.deactivated_at) -> :active
      membership_flag?(membership, "banned") -> :banned
      true -> :removed
    end
  end

  def banned?(%User{} = user), do: membership_state(user) == :banned

  @doc "Whether the user may reach no chat page: banned, kicked, or without a membership."
  def excluded?(%User{} = user), do: membership_state(user) in [:banned, :removed]
  def removed?(%User{} = user), do: membership_state(user) == :removed

  def hash_token(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc """
  Promote the member `subject_user_id` to owner. The scope must be an active owner now, in the
  database. Returns `{:ok, membership}`, or `{:error, reason}`: `:forbidden` for a scope that is
  not an owner, `:self`, or `:not_found` for a subject with no membership.
  """
  def promote_to_owner(%Scope{} = scope, subject_user_id) do
    change_ownership(scope, subject_user_id, true)
  end

  @doc """
  Demote the owner `subject_user_id`. The scope must be an active owner now, in the database, and
  cannot demote themselves. So the actor is still an owner after every demotion, and the
  server always keeps at least one owner. Returns the same errors as `promote_to_owner/2`.
  """
  def demote_from_owner(%Scope{} = scope, subject_user_id) do
    change_ownership(scope, subject_user_id, false)
  end

  def owner?(%User{membership: %Membership{is_owner: true}}), do: true
  def owner?(_), do: false

  # Every ownership decision runs under one lock and reads memberships after taking it.
  # Without the lock, two owners who demote each other at the same time each see the
  # other as an owner, and both demotions commit.
  # The advisory lock comes first, then `Visibility.authorize_write/3` takes both membership rows
  # `FOR UPDATE` and decides that the actor is an active owner. A non-owner is `:forbidden` before
  # the self check. The subject's own state is read only after those locks are held.
  defp change_ownership(%Scope{} = scope, subject_user_id, is_owner) do
    case Ecto.UUID.cast(subject_user_id) do
      {:ok, subject_id} -> run_change_ownership(scope, subject_id, is_owner)
      :error -> {:error, :not_found}
    end
  end

  defp run_change_ownership(%Scope{user_id: actor_id} = scope, subject_id, is_owner) do
    Repo.transaction(fn ->
      lock_ownership!()

      case Visibility.authorize_write(scope, :manage_ownership, subject_id) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      subject_membership = current_membership(subject_id)

      cond do
        actor_id == subject_id ->
          Repo.rollback(:self)

        is_nil(subject_membership) or not is_nil(subject_membership.deactivated_at) ->
          Repo.rollback(:not_found)

        subject_membership.is_owner == is_owner ->
          subject_membership

        true ->
          subject_membership |> Membership.ownership_changeset(is_owner) |> Repo.update!()
      end
    end)
  end

  defp current_membership(user_id), do: Repo.get_by(Membership, user_id: user_id)

  # A transaction-scoped Postgres advisory lock: it is released at commit or rollback.
  defp lock_ownership! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@ownership_lock_key])
  end

  defp create_membership!(%User{} = user, now) do
    %Membership{user_id: user.id, is_owner: false}
    |> Membership.join_changeset(now)
    |> Repo.insert!()
  end

  defp owner_exists? do
    Repo.exists?(
      from membership in Membership,
        where: membership.is_owner == true and is_nil(membership.deactivated_at)
    )
  end

  defp touch_session(token) do
    hashed_token = hash_token(token)
    threshold = DateTime.add(DateTime.utc_now(), -300, :second)

    from(session in UserSession,
      where: session.token_hash == ^hashed_token,
      where: is_nil(session.last_seen_at) or session.last_seen_at < ^threshold
    )
    |> Repo.update_all(set: [last_seen_at: DateTime.utc_now()])
  end

  defp heartbeat_presence(%User{id: user_id}) do
    _ = Ephemeral.heartbeat_presence(user_id)
    :ok
  end

  defp presence_status(last_active_at, now) do
    cond do
      is_nil(last_active_at) -> :offline
      DateTime.diff(now, last_active_at, :second) <= 300 -> :online
      DateTime.diff(now, last_active_at, :second) <= 3_600 -> :recent
      true -> :offline
    end
  end

  defp membership_flag?(membership, key) do
    flags = membership.flags || %{}

    case Map.get(flags, key) do
      true -> true
      "true" -> true
      _ -> false
    end
  end
end
