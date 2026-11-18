defmodule Rfchat.Chat.Channels do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Chat.Channel
  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.ChannelMembership
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.Topics
  alias Rfchat.Chat.Visibility
  alias Rfchat.Repo

  # Key of the transaction-scoped advisory lock that serializes channel management writes.
  @channel_tree_lock_key 7_314_002_002

  def list_channels(%Scope{} = scope) do
    Visibility.visible_channels(scope)
  end

  def list_channel_tree(%Scope{} = scope) do
    scope
    |> Visibility.visible_channels()
    |> build_channel_tree()
  end

  def build_channel_tree(channels) when is_list(channels) do
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

  def ensure_channel_memberships(%Scope{} = scope, channels) when is_list(channels) do
    # These rows store read state only; they do not grant channel access.
    user_id = scope.user_id
    channels = Enum.reject(channels, &(&1.kind == :category))
    channel_ids = Enum.map(channels, & &1.id)

    existing_channel_ids =
      ChannelMembership
      |> where(
        [membership],
        membership.user_id == ^user_id and membership.channel_id in ^channel_ids
      )
      |> select([membership], membership.channel_id)
      |> Repo.all()
      |> MapSet.new()

    missing_channels = Enum.reject(channels, &MapSet.member?(existing_channel_ids, &1.id))

    latest_messages =
      missing_channels
      |> Enum.map(& &1.id)
      |> latest_messages_by_channel()

    now = DateTime.utc_now()

    missing_channels
    |> Enum.each(fn channel ->
      latest_message =
        case Map.get(latest_messages, channel.id) do
          %Message{author_id: author_id} = message when author_id == user_id -> message
          _ -> nil
        end

      %ChannelMembership{channel_id: channel.id, user_id: user_id}
      |> ChannelMembership.changeset(%{
        joined_at: now,
        last_read_message_id: latest_message && latest_message.id,
        last_read_at: latest_message && latest_message.inserted_at
      })
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:channel_id, :user_id])
    end)

    :ok
  end

  def get_channel(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, channel_id} -> Visibility.visible_channel(scope, channel_id)
      :error -> nil
    end
  end

  def get_channel_by_slug(%Scope{} = scope, slug) do
    channel = Repo.get_by(Channel, slug: slug)
    if channel, do: get_channel(scope, channel.id), else: nil
  end

  def create_channel(%Scope{} = scope, attrs) do
    write_channel(scope, :server, :channel_created, fn _ ->
      attrs = put_position_if_missing(attrs)

      with {:ok, parent} <- authorize_parent(scope, attrs) do
        %Channel{} |> managed_channel_changeset(attrs, parent) |> Repo.insert()
      end
    end)
  end

  def change_channel(%Channel{} = channel, attrs \\ %{}) do
    Channel.changeset(channel, attrs)
  end

  def update_channel(%Scope{} = scope, channel_id, attrs) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id) do
      write_channel(scope, channel_id, :channel_updated, fn channel ->
        with {:ok, parent} <- authorize_parent(scope, attrs, channel.parent_channel_id) do
          channel |> managed_channel_changeset(attrs, parent) |> Repo.update()
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  @doc "Deletes a channel or category. A thread is refused: it goes with its starter message."
  def delete_channel(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id) do
      write_channel(scope, channel_id, :channel_deleted, fn channel ->
        cond do
          Channel.thread?(channel) ->
            {:error, :thread}

          channel.kind == :category ->
            from(child in Channel, where: child.parent_channel_id == ^channel.id)
            |> Repo.update_all(set: [parent_channel_id: nil])

            Repo.delete(channel)

          true ->
            Repo.delete(channel)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def move_channel(%Scope{} = scope, channel_id, direction) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id) do
      scope
      |> channel_transaction(channel_id, fn channel ->
        case adjacent_visible_sibling(scope, channel, direction) do
          {:ok, sibling} -> swap_positions(channel, sibling)
          {:error, :edge} -> {:ok, Visibility.visible_channel(scope, channel_id)}
          {:error, _} -> {:error, :not_found}
        end
      end)
      |> tap(&broadcast_reorder/1)
    else
      :error -> {:error, :not_found}
    end
  end

  # Open GuildLive sidebars reload their channel order after the move commits.
  defp broadcast_reorder({:ok, _channel}), do: Topics.broadcast_guild(:channels_reordered)
  defp broadcast_reorder(_error), do: :ok

  defp swap_positions(channel, sibling) do
    [first, second] = [channel.id, sibling.id] |> Enum.sort() |> Enum.map(&lock_channel/1)

    with {:ok, moved_first} <- Repo.update(Channel.changeset(first, %{position: second.position})),
         {:ok, moved_second} <-
           Repo.update(Channel.changeset(second, %{position: first.position})) do
      {:ok, Enum.find([moved_first, moved_second], &(&1.id == channel.id))}
    end
  end

  defp write_channel(scope, target, event, change) do
    case channel_transaction(scope, target, change) do
      {:ok, channel} = result ->
        Topics.broadcast_guild({event, channel})
        result

      error ->
        error
    end
  end

  # Every channel management write runs here. The tree lock comes first, so two management writes
  # never interleave: the second one decides from the tree the first one committed, and no two of
  # them wait on each other's channel rows. Then the decision takes its membership locks, then the
  # target row is locked (`:server` has none) and `change` runs on it.
  defp channel_transaction(scope, target, change) do
    Repo.transact(fn ->
      lock_channel_tree!()

      with :ok <-
             Visibility.authorize_write(scope, :manage_channels, authorization_target(target)),
           {:ok, channel} <- lock_target(target) do
        change.(channel)
      end
    end)
  end

  defp authorization_target(:server), do: :server
  defp authorization_target(channel_id), do: %Channel{id: channel_id}

  defp lock_target(:server), do: {:ok, nil}

  defp lock_target(channel_id) do
    case lock_channel(channel_id) do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Takes the channel-tree lock exclusively. Every channel management write takes it first, and an
  overwrite write (`Rfchat.Chat.ChannelOverwrites`) takes it after the role-list lock. Must run
  inside the write transaction.
  """
  def lock_channel_tree! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@channel_tree_lock_key])
    :ok
  end

  def lock_channel(id) do
    Repo.one(from(channel in Channel, where: channel.id == ^id, lock: "FOR UPDATE"))
  end

  # The scoped decision answers first, so a hidden parent and a missing one give the same refusal.
  # The kind is checked on the row the decision locked, and only for a parent that is set.
  defp authorize_parent(scope, attrs, fallback \\ nil) do
    parent_id = Map.get(attrs, :parent_channel_id, Map.get(attrs, "parent_channel_id", fallback))

    if is_nil(parent_id) do
      {:ok, nil}
    else
      with {:ok, parent_id} <- cast_parent_id(parent_id),
           :ok <- Visibility.authorize_write(scope, :manage_channels, %Channel{id: parent_id}),
           %Channel{} = parent <- lock_channel(parent_id) do
        {:ok, parent}
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end
  end

  defp cast_parent_id(parent_id) do
    case Ecto.UUID.cast(parent_id) do
      {:ok, parent_id} -> {:ok, parent_id}
      :error -> {:error, :not_found}
    end
  end

  defp next_channel_position do
    (Repo.one(from(channel in Channel, select: max(channel.position))) || 0) + 1
  end

  defp put_position_if_missing(attrs) do
    key = if Enum.any?(Map.keys(attrs), &is_atom/1), do: :position, else: "position"
    Map.put_new(attrs, key, next_channel_position())
  end

  defp adjacent_visible_sibling(scope, channel, direction) do
    siblings =
      Visibility.visible_channels(scope)
      |> Enum.filter(&(&1.parent_channel_id == channel.parent_channel_id))
      |> sort_channels()

    index = Enum.find_index(siblings, &(&1.id == channel.id))

    delta =
      case direction do
        d when d in [:up, "up"] -> -1
        d when d in [:down, "down"] -> 1
        _ -> nil
      end

    cond do
      is_nil(index) or is_nil(delta) -> {:error, :not_found}
      index + delta < 0 or index + delta >= length(siblings) -> {:error, :edge}
      true -> {:ok, Enum.at(siblings, index + delta)}
    end
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
    channel.kind != :category and not Channel.thread?(channel)
  end

  # A manager places a channel only under a category. Any other parent would make the channel a
  # child of a channel, whose visibility rules are a thread's.
  defp managed_channel_changeset(channel, attrs, parent) do
    changeset = Channel.changeset(channel, attrs)

    case parent do
      %Channel{kind: :category} -> changeset
      nil -> changeset
      %Channel{} -> Ecto.Changeset.add_error(changeset, :parent_channel_id, "must be a category")
    end
  end
end
