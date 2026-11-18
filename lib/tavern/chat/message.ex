defmodule Tavern.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field(:body, :string)

    field(:kind, Ecto.Enum,
      values: [:default, :system, :reply, :thread_starter, :call, :slash_command],
      default: :default
    )

    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    field(:pinned_at, :utc_datetime_usec)
    field(:nonce, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:channel, Tavern.Chat.Channel)
    belongs_to(:author, Tavern.Chat.User)
    belongs_to(:reply_to, __MODULE__)

    has_many(:attachments, Tavern.Chat.MessageAttachment)
    has_many(:reactions, Tavern.Chat.Reaction)
    has_many(:reports, Tavern.Chat.MessageReport)
    has_many(:user_mentions, Tavern.Chat.MessageUserMention)
    has_many(:role_mentions, Tavern.Chat.MessageRoleMention)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  A changeset for what an author writes: the body and the composer's metadata. The server sets
  every other field itself (`kind`, `nonce`, `edited_at`, `deleted_at`, `pinned_at`), so a client
  cannot forge a system message, a pin or a deletion.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :metadata])
    |> validate_required([:body])
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, min: 1, max: 4000)
  end

  @doc "A changeset for a new message: what `changeset/2` takes, plus the message it replies to."
  def create_changeset(message, attrs) do
    message
    |> cast(attrs, [:reply_to_id])
    |> changeset(attrs)
  end

  def deleted?(%{deleted_at: deleted_at}), do: not is_nil(deleted_at)
end
