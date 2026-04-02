defmodule Rfchat.Chat.EmojiRole do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "emoji_roles" do
    belongs_to(:emoji, Rfchat.Chat.Emoji)
    belongs_to(:role, Rfchat.Chat.Role)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(emoji_role, attrs) do
    emoji_role
    |> cast(attrs, [:emoji_id, :role_id])
    |> validate_required([:emoji_id, :role_id])
    |> unique_constraint([:emoji_id, :role_id])
  end
end
