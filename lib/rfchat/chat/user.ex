defmodule Rfchat.Chat.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field(:username, :string)
    field(:display_name, :string)
    field(:email, :string)
    field(:hashed_password, :string)
    field(:password, :string, virtual: true, redact: true)
    field(:confirmed_at, :utc_datetime_usec)
    field(:bio, :string)
    field(:bot, :boolean, default: false)
    field(:system, :boolean, default: false)
    field(:deleted_at, :utc_datetime_usec)

    belongs_to(:avatar_asset, Rfchat.Chat.MediaAsset)
    belongs_to(:banner_asset, Rfchat.Chat.MediaAsset)

    has_many(:messages, Rfchat.Chat.Message, foreign_key: :author_id)
    has_one(:membership, Rfchat.Chat.Membership)
    has_many(:member_roles, Rfchat.Chat.MemberRole)
    has_many(:channel_memberships, Rfchat.Chat.ChannelMembership)
    has_many(:channel_permission_overwrites, Rfchat.Chat.ChannelPermissionOverwrite)
    has_many(:reactions, Rfchat.Chat.Reaction)
    has_many(:invites, Rfchat.Chat.Invite, foreign_key: :inviter_id)
    has_many(:invite_uses, Rfchat.Chat.InviteUse)
    has_many(:moderation_cases_started, Rfchat.Chat.ModerationCase, foreign_key: :actor_user_id)

    has_many(:moderation_cases_targeting, Rfchat.Chat.ModerationCase,
      foreign_key: :subject_user_id
    )

    has_many(:message_reports, Rfchat.Chat.MessageReport, foreign_key: :reporter_user_id)
    has_many(:sessions, Rfchat.Chat.UserSession)
    has_many(:bot_tokens, Rfchat.Chat.BotToken)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The profile fields a member edits on their own account. It casts no email, which has its own
  changeset with a password check, and no asset id, which only the server sets.
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :bio])
    |> validate_required([:username, :display_name])
    |> validate_profile_fields()
  end

  @doc """
  The fields an account is created with. Member registration, bot creation and bot edits all use
  it. It casts no asset id.
  """
  def account_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :email, :bio])
    |> validate_required([:username, :display_name, :email])
    |> validate_profile_fields()
    |> validate_email()
    |> unique_constraint(:email)
  end

  @doc """
  The email change. It casts only the email. The caller checks the account password before it
  writes the changeset.
  """
  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_email()
    |> unique_constraint(:email)
  end

  @doc """
  A changeset for a new account. It hashes the password unless `hash_password: false`, which
  form validation passes: bcrypt costs about a quarter second, and an anonymous visitor sends a
  validate event on every keystroke.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> account_changeset(attrs)
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password(opts)
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password([])
  end

  def login_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> validate_email()
  end

  defp validate_profile_fields(changeset) do
    changeset
    |> validate_length(:username, min: 2, max: 24)
    |> validate_length(:display_name, min: 1, max: 40)
    |> validate_length(:bio, max: 200)
    |> validate_format(:username, ~r/^[a-z0-9_]+$/,
      message: "must contain only lowercase letters, numbers, and underscores"
    )
    |> unique_constraint(:username)
  end

  defp validate_email(changeset) do
    changeset
    |> validate_length(:email, max: 160)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> update_change(:email, &String.downcase/1)
  end

  defp validate_password(changeset, opts) do
    changeset
    # Bcrypt reads only the first 72 bytes, so the limit counts bytes, not characters.
    |> validate_length(:password, min: 12)
    |> validate_length(:password, max: 72, count: :bytes)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    password = get_change(changeset, :password)

    if Keyword.get(opts, :hash_password, true) and changeset.valid? and is_binary(password) do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end
end
