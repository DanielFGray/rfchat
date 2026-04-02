defmodule Rfchat.Chat.Reaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "reactions" do
    field(:emoji_unicode, :string)

    belongs_to(:message, Rfchat.Chat.Message)
    belongs_to(:user, Rfchat.Chat.User)
    belongs_to(:emoji, Rfchat.Chat.Emoji)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:message_id, :user_id, :emoji_id, :emoji_unicode])
    |> validate_required([:message_id, :user_id])
    |> validate_emoji_choice()
    |> unique_constraint([:message_id, :user_id, :emoji_id])
    |> unique_constraint([:message_id, :user_id, :emoji_unicode])
  end

  defp validate_emoji_choice(changeset) do
    emoji_id = get_field(changeset, :emoji_id)
    emoji_unicode = get_field(changeset, :emoji_unicode)

    case {emoji_id, emoji_unicode} do
      {nil, nil} -> add_error(changeset, :emoji_id, "or emoji_unicode must be present")
      {_, nil} -> changeset
      {nil, _} -> changeset
      {_, _} -> add_error(changeset, :emoji_unicode, "cannot coexist with emoji_id")
    end
  end
end
