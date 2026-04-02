defmodule Rfchat.Accounts do
  @moduledoc """
  Authentication and account management for rfchat users.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.Membership
  alias Rfchat.Chat.User
  alias Rfchat.Chat.UserSession
  alias Rfchat.Chat.Role
  alias Rfchat.Repo

  @session_valid_days 30

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  def get_user!(id), do: Repo.get!(User, id)

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

    active_sessions =
      from(session in UserSession,
        where: session.context == "session",
        where: is_nil(session.revoked_at) and session.expires_at > ^now,
        group_by: session.user_id,
        select: {session.user_id, max(session.last_seen_at)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(list_members(), fn user ->
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

      owner_candidate? = not owner_exists?()

      membership =
        create_membership!(user, now, owner_candidate?)

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

  def change_registration_user(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  def dummy_login_changeset do
    User.login_changeset(%User{}, %{})
  end

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(String.downcase(email))

    if valid_user_password?(user, password), do: user
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

  def user_scope(%User{} = user) do
    default_role = Repo.get_by(Role, is_default: true)

    %Scope{
      user: user,
      membership: user.membership,
      roles: Enum.map(user.member_roles || [], & &1.role),
      base_permissions: Authorization.base_permissions(user, default_role)
    }
  end

  def hash_token(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  defp create_membership!(%User{} = user, now, owner_candidate?) do
    attrs = %{joined_at: now, is_owner: owner_candidate?}

    case %Membership{user_id: user.id}
         |> Membership.changeset(attrs)
         |> Repo.insert() do
      {:ok, membership} ->
        membership

      {:error, changeset} ->
        if owner_candidate? and owner_constraint_error?(changeset) do
          %Membership{user_id: user.id}
          |> Membership.changeset(%{joined_at: now, is_owner: false})
          |> Repo.insert!()
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp owner_exists? do
    Repo.exists?(from(membership in Membership, where: membership.is_owner == true))
  end

  defp owner_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:is_owner, _details} -> true
      _other -> false
    end)
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

  defp presence_status(last_active_at, now) do
    cond do
      is_nil(last_active_at) -> :offline
      DateTime.diff(now, last_active_at, :second) <= 300 -> :online
      DateTime.diff(now, last_active_at, :second) <= 3_600 -> :recent
      true -> :offline
    end
  end
end
