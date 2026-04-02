defmodule Rfchat.Chat.Message do
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

    belongs_to(:channel, Rfchat.Chat.Channel)
    belongs_to(:author, Rfchat.Chat.User)
    belongs_to(:reply_to, __MODULE__)

    has_many(:attachments, Rfchat.Chat.MessageAttachment)
    has_many(:reactions, Rfchat.Chat.Reaction)
    has_many(:reports, Rfchat.Chat.MessageReport)
    has_many(:user_mentions, Rfchat.Chat.MessageUserMention)
    has_many(:role_mentions, Rfchat.Chat.MessageRoleMention)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :body,
      :kind,
      :reply_to_id,
      :edited_at,
      :deleted_at,
      :pinned_at,
      :nonce,
      :metadata
    ])
    |> validate_required([:body])
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, min: 1, max: 4000)
  end
end
