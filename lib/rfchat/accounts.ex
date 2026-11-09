defmodule Rfchat.Accounts do
  @moduledoc """
  Authentication and account management for rfchat users.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.BotToken
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.Permissions
  alias Rfchat.Chat.User
  alias Rfchat.Chat.UserSession
  alias Rfchat.Ephemeral
  alias Rfchat.Repo

  @session_valid_days 30
  # An arbitrary constant that names "server ownership" among Postgres advisory locks.
  @ownership_lock_key 7_314_002_001

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_with_membership!(id) do
    User
    |> Repo.get!(id)
    |> Repo.preload([:membership, member_roles: :role])
  end

  def list_members do
    User
    |> join(:inner, [user], membership in Membership, on: membership.user_id == user.id)
    |> where([user, membership], is_nil(user.deleted_at) and is_nil(membership.deactivated_at))
    |> order_by([_user, membership], desc: membership.is_owner, asc: membership.joined_at)
    |> preload([user, _membership], [:membership])
    |> Repo.all()
  end

  def list_members_with_presence do
    now = DateTime.utc_now()
    members = list_members()

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

  def delete_bot_token(token) when is_binary(token) do
    hashed_token = hash_token(token)
    now = DateTime.utc_now()

    from(bot_token in BotToken, where: bot_token.token_hash == ^hashed_token)
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  def user_scope(%User{} = user) do
    default_role = Permissions.default_role()

    %Scope{
      user: user,
      membership: user.membership,
      roles: Enum.map(user.member_roles || [], & &1.role),
      base_permissions: Authorization.base_permissions(user, default_role)
    }
  end

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
  def removed?(%User{} = user), do: membership_state(user) == :removed

  def timed_out?(%User{membership: %{timeout_until: timeout_until}})
      when not is_nil(timeout_until) do
    DateTime.compare(timeout_until, DateTime.utc_now()) == :gt
  end

  def timed_out?(%User{}), do: false

  def hash_token(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc """
  Promote a user to owner. The `actor` must be an active owner now, in the database.
  Returns `{:ok, membership}` or `{:error, reason}`.
  """
  def promote_to_owner(%User{} = actor, %User{} = subject) do
    change_ownership(actor, subject, true)
  end

  @doc """
  Demote a user from owner. The `actor` must be an active owner now, in the database, and
  cannot demote themselves. So the actor is still an owner after every demotion, and the
  server always keeps at least one owner.
  Returns `{:ok, membership}` or `{:error, reason}`.
  """
  def demote_from_owner(%User{} = actor, %User{} = subject) do
    change_ownership(actor, subject, false)
  end

  def owner?(%User{membership: %Membership{is_owner: true}}), do: true
  def owner?(_), do: false

  # Every ownership decision runs under one lock and reads memberships after taking it.
  # Without the lock, two owners who demote each other at the same time each see the
  # other as an owner, and both demotions commit.
  defp change_ownership(%User{id: actor_id}, %User{id: subject_id}, is_owner) do
    Repo.transaction(fn ->
      lock_ownership!()
      actor_membership = current_membership(actor_id)
      subject_membership = current_membership(subject_id)

      cond do
        not active_owner?(actor_membership) ->
          Repo.rollback(:forbidden)

        actor_id == subject_id ->
          Repo.rollback(:self)

        is_nil(subject_membership) ->
          Repo.rollback(:no_membership)

        subject_membership.is_owner == is_owner ->
          subject_membership

        true ->
          subject_membership |> Membership.ownership_changeset(is_owner) |> Repo.update!()
      end
    end)
  end

  defp current_membership(user_id), do: Repo.get_by(Membership, user_id: user_id)

  defp active_owner?(%Membership{is_owner: true, deactivated_at: nil}), do: true
  defp active_owner?(_membership), do: false

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
