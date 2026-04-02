defmodule Rfchat.Chat.Role do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "roles" do
    field(:name, :string)
    field(:description, :string)
    field(:color, :integer, default: 0)
    field(:permissions, :integer, default: 0)
    field(:position, :integer, default: 0)
    field(:mentionable, :boolean, default: false)
    field(:hoist, :boolean, default: false)
    field(:managed, :boolean, default: false)
    field(:is_default, :boolean, default: false)

    belongs_to(:icon_asset, Rfchat.Chat.MediaAsset)

    has_many(:member_roles, Rfchat.Chat.MemberRole)
    has_many(:emoji_roles, Rfchat.Chat.EmojiRole)
    has_many(:permission_overwrites, Rfchat.Chat.ChannelPermissionOverwrite)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [
      :name,
      :description,
      :color,
      :permissions,
      :position,
      :mentionable,
      :hoist,
      :managed,
      :is_default,
      :icon_asset_id
    ])
    |> validate_required([:name, :permissions, :position])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:permissions, greater_than_or_equal_to: 0)
  end
end
