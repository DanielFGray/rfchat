defmodule Tavern.Chat.Role do
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
    field(:member_count, :integer, virtual: true)

    belongs_to(:icon_asset, Tavern.Chat.MediaAsset)

    has_many(:member_roles, Tavern.Chat.MemberRole)
    has_many(:emoji_roles, Tavern.Chat.EmojiRole)
    has_many(:permission_overwrites, Tavern.Chat.ChannelPermissionOverwrite)

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

  @doc """
  The fields a person may set on a role. Position, `managed` and `is_default` are set by
  `Tavern.Chat.Roles`, never from input. The default role takes only its permissions.
  """
  def manage_changeset(%__MODULE__{is_default: true} = role, attrs) do
    role
    |> cast(attrs, [:permissions])
    |> validate_permissions()
  end

  def manage_changeset(%__MODULE__{} = role, attrs) do
    role
    |> cast(attrs, [:name, :description, :color, :permissions, :mentionable, :hoist])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:color, greater_than_or_equal_to: 0, less_than_or_equal_to: 0xFFFFFF)
    |> validate_permissions()
  end

  # The owner skips the subset rule, so the bits are checked against the known flags here.
  defp validate_permissions(changeset) do
    all = Tavern.Chat.Authorization.all_permissions()

    changeset
    |> validate_required([:permissions])
    |> validate_change(:permissions, fn :permissions, permissions ->
      if permissions >= 0 and Bitwise.band(permissions, Bitwise.bnot(all)) == 0,
        do: [],
        else: [permissions: "has unknown permission bits"]
    end)
  end
end
