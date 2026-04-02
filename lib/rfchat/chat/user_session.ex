defmodule Rfchat.Chat.UserSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_sessions" do
    field(:token_hash, :binary)
    field(:context, :string, default: "session")
    field(:sent_to, :string)
    field(:user_agent, :string)
    field(:ip_address, :string)
    field(:last_seen_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:user, Rfchat.Chat.User)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :user_id,
      :token_hash,
      :context,
      :sent_to,
      :user_agent,
      :ip_address,
      :last_seen_at,
      :expires_at,
      :revoked_at
    ])
    |> validate_required([:user_id, :token_hash, :context, :expires_at])
    |> unique_constraint(:token_hash)
  end

  def session_changeset(session, attrs), do: changeset(session, attrs)
end
