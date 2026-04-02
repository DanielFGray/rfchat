defmodule Rfchat.Chat.Emoji do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "emojis" do
    field(:name, :string)
    field(:shortcode, :string)
    field(:requires_colons, :boolean, default: true)
    field(:managed, :boolean, default: false)
    field(:available, :boolean, default: true)
    field(:listed, :boolean, default: true)

    belongs_to(:asset, Rfchat.Chat.MediaAsset)
    belongs_to(:creator, Rfchat.Chat.User)

    has_many(:emoji_roles, Rfchat.Chat.EmojiRole)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(emoji, attrs) do
    emoji
    |> cast(attrs, [
      :name,
      :shortcode,
      :asset_id,
      :requires_colons,
      :managed,
      :available,
      :listed
    ])
    |> validate_required([:name, :shortcode, :asset_id])
    |> validate_length(:name, min: 2, max: 64)
    |> validate_format(:shortcode, ~r/^:[a-z0-9_+-]+:$/, message: "must look like :party_blob:")
    |> unique_constraint(:name)
    |> unique_constraint(:shortcode)
  end
end
