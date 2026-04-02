defmodule Rfchat.Chat.MessageRoleMention do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_role_mentions" do
    belongs_to(:message, Rfchat.Chat.Message)
    belongs_to(:mentioned_role, Rfchat.Chat.Role)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(mention, attrs) do
    mention
    |> cast(attrs, [:message_id, :mentioned_role_id])
    |> validate_required([:message_id, :mentioned_role_id])
    |> unique_constraint([:message_id, :mentioned_role_id])
  end
end
