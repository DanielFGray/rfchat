defmodule Rfchat.Chat.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channels" do
    field(:name, :string)
    field(:slug, :string)
    field(:position, :integer, default: 0)
    field(:topic, :string)
    field(:unread_count, :integer, virtual: true, default: 0)

    field(:kind, Ecto.Enum,
      values: [
        :text,
        :category,
        :announcement,
        :forum,
        :voice,
        :stage,
        :thread_public,
        :thread_private,
        :thread_announcement
      ],
      default: :text
    )

    field(:nsfw, :boolean, default: false)
    field(:slowmode_seconds, :integer, default: 0)
    field(:default_auto_archive_minutes, :integer, default: 1440)
    field(:archived_at, :utc_datetime_usec)
    field(:locked_at, :utc_datetime_usec)

    belongs_to(:parent_channel, __MODULE__)
    belongs_to(:created_by, Rfchat.Chat.User)
    belongs_to(:starter_message, Rfchat.Chat.Message)

    has_many(:messages, Rfchat.Chat.Message)
    has_many(:child_channels, __MODULE__, foreign_key: :parent_channel_id)
    has_many(:channel_memberships, Rfchat.Chat.ChannelMembership)
    has_many(:permission_overwrites, Rfchat.Chat.ChannelPermissionOverwrite)
    has_many(:tags, Rfchat.Chat.ChannelTag)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :name,
      :slug,
      :position,
      :topic,
      :kind,
      :parent_channel_id,
      :created_by_id,
      :starter_message_id,
      :nsfw,
      :slowmode_seconds,
      :default_auto_archive_minutes,
      :archived_at,
      :locked_at
    ])
    |> update_change(:name, &normalize_text/1)
    |> update_change(:slug, &normalize_slug/1)
    |> update_change(:topic, &normalize_optional_text/1)
    |> validate_required([:name, :slug, :position])
    |> validate_length(:name, min: 1, max: 40)
    |> validate_length(:slug, min: 1, max: 48)
    |> validate_length(:topic, max: 160)
    |> validate_number(:slowmode_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 21_600
    )
    |> validate_number(:default_auto_archive_minutes,
      greater_than_or_equal_to: 60,
      less_than_or_equal_to: 10_080
    )
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> validate_category_parenting()
    |> unique_constraint(:slug)
  end

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value

  defp normalize_optional_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_text(value), do: value

  defp normalize_slug(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_slug(value), do: value

  defp validate_category_parenting(changeset) do
    if get_field(changeset, :kind) == :category and get_field(changeset, :parent_channel_id) do
      add_error(changeset, :parent_channel_id, "categories cannot be nested")
    else
      changeset
    end
  end
end
