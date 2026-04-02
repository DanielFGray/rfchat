defmodule Rfchat.ChatFixtures do
  @moduledoc false

  alias Rfchat.Accounts
  alias Rfchat.Chat
  alias Rfchat.Chat.ChannelPermissionOverwrite
  alias Rfchat.Chat.Emoji
  alias Rfchat.Chat.MemberRole
  alias Rfchat.Chat.MediaAsset
  alias Rfchat.Chat.Reaction
  alias Rfchat.Chat.Role
  alias Rfchat.Repo

  def unique_username, do: "user_#{System.unique_integer([:positive])}"
  def unique_slug, do: "channel-#{System.unique_integer([:positive])}"

  def user_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        email: "#{unique_username()}@example.com",
        username: unique_username(),
        display_name: "Test User",
        password: "supersecurepass"
      })

    {:ok, user} = Accounts.register_user(attrs)
    user
  end

  def channel_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "General",
        slug: unique_slug(),
        position: System.unique_integer([:positive])
      })

    {:ok, channel} = Chat.create_channel(attrs)
    channel
  end

  def message_fixture(channel, author, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{body: "hello world"})

    {:ok, message} = Chat.create_message(channel, author, attrs)
    message
  end

  def role_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Role #{System.unique_integer([:positive])}",
        permissions: 0,
        position: System.unique_integer([:positive])
      })

    {:ok, role} =
      %Role{}
      |> Role.changeset(attrs)
      |> Repo.insert()

    role
  end

  def member_role_fixture(user, role, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{user_id: user.id, role_id: role.id})

    {:ok, member_role} =
      %MemberRole{}
      |> MemberRole.changeset(attrs)
      |> Repo.insert()

    member_role
  end

  def channel_permission_overwrite_fixture(channel, attrs) do
    {:ok, overwrite} =
      %ChannelPermissionOverwrite{}
      |> ChannelPermissionOverwrite.changeset(Map.put(attrs, :channel_id, channel.id))
      |> Repo.insert()

    overwrite
  end

  def reaction_fixture(message, user, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{message_id: message.id, user_id: user.id, emoji_unicode: "👍"})

    {:ok, reaction} =
      %Reaction{}
      |> Reaction.changeset(attrs)
      |> Repo.insert()

    reaction
  end

  def media_asset_fixture(user, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        uploader_id: user.id,
        kind: :emoji,
        storage_provider: "local",
        storage_key: "uploads/emojis/test-#{System.unique_integer([:positive])}.png",
        original_filename: "emoji.png",
        content_type: "image/png",
        byte_size: 128,
        sha256: String.duplicate("a", 64)
      })

    {:ok, asset} =
      %MediaAsset{}
      |> MediaAsset.changeset(attrs)
      |> Repo.insert()

    asset
  end

  def emoji_fixture(user, attrs \\ %{}) do
    asset = Map.get(attrs, :asset) || Map.get(attrs, "asset") || media_asset_fixture(user)

    attrs =
      attrs
      |> Map.new(fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)
      |> Map.drop(["asset"])
      |> Enum.into(%{
        "name" => "blob_#{System.unique_integer([:positive])}",
        "shortcode" => ":blob_#{System.unique_integer([:positive])}:",
        "asset_id" => asset.id,
        "available" => true,
        "listed" => true
      })

    {:ok, emoji} =
      %Emoji{creator_id: user.id}
      |> Emoji.changeset(attrs)
      |> Repo.insert()

    Repo.preload(emoji, [:asset, :emoji_roles])
  end
end
