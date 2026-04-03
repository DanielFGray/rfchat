defmodule Rfchat.Chat.Channels do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.ChannelMembership
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  @channel_events_topic "chat:channels"

  def list_channels do
    Channel
    |> order_by([channel], asc: channel.position, asc: channel.inserted_at)
    |> Repo.all()
  end

  def list_channel_tree do
    channels = list_channels()
    categories = Enum.filter(channels, &(&1.kind == :category))
    category_ids = MapSet.new(Enum.map(categories, & &1.id))

    uncategorized =
      Enum.filter(
        channels,
        &(visible_text_channel?(&1) and root_level_channel?(&1, category_ids))
      )

    categorized_sections =
      Enum.map(categories, fn category ->
        %{
          category: category,
          channels:
            channels
            |> Enum.filter(&(&1.parent_channel_id == category.id and visible_text_channel?(&1)))
            |> sort_channels()
        }
      end)

    categorized_sections ++
      if uncategorized == [] do
        []
      else
        [%{category: nil, channels: sort_channels(uncategorized)}]
      end
  end

  def list_channels_for_user(%User{} = user) do
    visible_channels_for_user(user)
    |> Enum.filter(&visible_text_channel?/1)
  end

  def list_channel_tree_for_user(%User{} = user) do
    channels = visible_channels_for_user(user)
    categories = Enum.filter(channels, &(&1.kind == :category))
    category_ids = MapSet.new(Enum.map(categories, & &1.id))

    uncategorized =
      Enum.filter(
        channels,
        &(visible_text_channel?(&1) and root_level_channel?(&1, category_ids))
      )

    categorized_sections =
      Enum.map(categories, fn category ->
        %{
          category: category,
          channels:
            channels
            |> Enum.filter(&(&1.parent_channel_id == category.id and visible_text_channel?(&1)))
            |> sort_channels()
        }
      end)
      |> Enum.reject(&(&1.channels == []))

    categorized_sections ++
      if uncategorized == [] do
        []
      else
        [%{category: nil, channels: sort_channels(uncategorized)}]
      end
  end

  def ensure_channel_memberships_for_user(%User{} = user, channels) when is_list(channels) do
    channel_ids = Enum.map(channels, & &1.id)

    existing_channel_ids =
      ChannelMembership
      |> where(
        [membership],
        membership.user_id == ^user.id and membership.channel_id in ^channel_ids
      )
      |> select([membership], membership.channel_id)
      |> Repo.all()
      |> MapSet.new()

    latest_messages = latest_messages_by_channel(channel_ids)
    now = DateTime.utc_now()

    channels
    |> Enum.reject(&MapSet.member?(existing_channel_ids, &1.id))
    |> Enum.each(fn channel ->
      latest_message =
        case Map.get(latest_messages, channel.id) do
          %Message{author_id: author_id} = message when author_id == user.id -> message
          _ -> nil
        end

      %ChannelMembership{channel_id: channel.id, user_id: user.id}
      |> ChannelMembership.changeset(%{
        joined_at: now,
        last_read_message_id: latest_message && latest_message.id,
        last_read_at: latest_message && latest_message.inserted_at
      })
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:channel_id, :user_id])
    end)

    :ok
  end

  def get_channel!(id), do: Repo.get!(Channel, id)

  def get_channel(id), do: Repo.get(Channel, id)

  def get_channel_by_slug!(slug) do
    Repo.get_by!(Channel, slug: slug)
  end

  def get_channel_by_slug_for_user(slug, %User{} = user) do
    default_role = default_role()

    channel =
      Channel
      |> preload([:permission_overwrites])
      |> Repo.get_by(slug: slug)

    cond do
      is_nil(channel) ->
        {:error, :not_found}

      not visible_text_channel?(channel) ->
        {:error, :not_found}

      Authorization.can_view_channel?(user, channel, default_role) ->
        {:ok, channel}

      true ->
        {:error, :forbidden}
    end
  end

  def create_channel(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, channel} ->
        broadcast({:channel_created, channel})
        {:ok, channel}

      error ->
        error
    end
  end

  def change_channel(%Channel{} = channel, attrs \\ %{}) do
    Channel.changeset(channel, attrs)
  end

  def update_channel(%Channel{} = channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_channel} ->
        broadcast({:channel_updated, updated_channel})
        {:ok, updated_channel}

      error ->
        error
    end
  end

  def delete_channel(%Channel{} = channel) do
    Repo.delete(channel)
    |> case do
      {:ok, deleted_channel} ->
        broadcast({:channel_deleted, deleted_channel})
        {:ok, deleted_channel}

      error ->
        error
    end
  end

  def reorder_channels(section_attrs) when is_list(section_attrs) do
    Repo.transaction(fn ->
      Enum.with_index(section_attrs)
      |> Enum.each(fn {section, section_index} ->
        category = Map.get(section, :category) || Map.get(section, "category")
        channels = Map.get(section, :channels) || Map.get(section, "channels") || []

        category_id = normalize_optional_binary_id(category)

        if category_id do
          category = Repo.get!(Channel, category_id)

          category
          |> Channel.changeset(%{
            position: section_index * 1_000,
            parent_channel_id: nil,
            kind: :category
          })
          |> Repo.update!()
        end

        Enum.with_index(channels)
        |> Enum.each(fn {channel_id, channel_index} ->
          channel = Repo.get!(Channel, channel_id)

          channel
          |> Channel.changeset(%{
            position: section_index * 1_000 + channel_index + 1,
            parent_channel_id: category_id
          })
          |> Repo.update!()
        end)
      end)
    end)
    |> case do
      {:ok, _result} ->
        broadcast(:channels_reordered)
        {:ok, list_channels()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def default_channel_for_user(%User{} = user) do
    user
    |> list_channels_for_user()
    |> List.first()
  end

  defp visible_channels_for_user(%User{} = user) do
    default_role = default_role()

    Channel
    |> order_by([channel], asc: channel.position, asc: channel.inserted_at)
    |> preload([:permission_overwrites])
    |> Repo.all()
    |> Enum.filter(&Authorization.can_view_channel?(user, &1, default_role))
  end

  defp latest_messages_by_channel([]), do: %{}

  defp latest_messages_by_channel(channel_ids) do
    from(message in Message,
      where: message.channel_id in ^channel_ids and is_nil(message.deleted_at),
      distinct: message.channel_id,
      order_by: [asc: message.channel_id, desc: message.inserted_at, desc: message.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.channel_id, &1})
  end

  defp sort_channels(channels) do
    Enum.sort_by(channels, &{&1.position, &1.inserted_at})
  end

  defp root_level_channel?(channel, category_ids) do
    is_nil(channel.parent_channel_id) or
      not MapSet.member?(category_ids, channel.parent_channel_id)
  end

  defp visible_text_channel?(channel) do
    channel.kind not in [:category, :thread_public, :thread_private, :thread_announcement]
  end

  defp normalize_optional_binary_id(nil), do: nil
  defp normalize_optional_binary_id(""), do: nil
  defp normalize_optional_binary_id(value), do: value

  defp default_role do
    Repo.get_by(Role, is_default: true)
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast_from(Rfchat.PubSub, self(), @channel_events_topic, message)
  end
end
