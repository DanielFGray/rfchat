defmodule Rfchat.Chat.BotToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "bot_tokens" do
    field :token_hash, :binary
    field :label, :string
    field :last_used_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, Rfchat.Chat.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(bot_token, attrs) do
    bot_token
    |> cast(attrs, [:user_id, :token_hash, :label, :last_used_at, :expires_at, :revoked_at])
    |> validate_required([:user_id, :token_hash])
    |> validate_length(:label, max: 120)
    |> unique_constraint(:token_hash)
  end
end
