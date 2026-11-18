defmodule Rfchat.Chat.Threads do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Accounts.Scope
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Channels
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.Topics
  alias Rfchat.Chat.Visibility
  alias Rfchat.Repo

  defp list_threads_for_channel(channel_ids) do
    Channel
    |> where(
      [channel],
      channel.parent_channel_id in ^channel_ids and channel.kind == :thread_public and
        is_nil(channel.archived_at)
    )
    |> order_by([channel], asc: channel.inserted_at, asc: channel.id)
    |> preload([:parent_channel, starter_message: :author])
    |> Repo.all()
  end

  def thread_summaries_for_channel(%Scope{} = scope, channel_id) do
    with {:ok, channel_id} <- Ecto.UUID.cast(channel_id) do
      thread_summaries_for_visible_channel(scope, channel_id)
    else
      :error -> %{}
    end
  end

  defp thread_summaries_for_visible_channel(scope, channel_id) do
    visible = Visibility.visible_channels(scope)
    visible_ids = MapSet.new(Enum.map(visible, & &1.id))

    threads =
      if MapSet.member?(visible_ids, channel_id),
        do:
          list_threads_for_channel([channel_id])
          |> Enum.filter(&MapSet.member?(visible_ids, &1.id)),
        else: []

    thread_ids = Enum.map(threads, & &1.id)

    reply_counts =
      if thread_ids == [] do
        %{}
      else
        from(message in Message,
          where: message.channel_id in ^thread_ids and is_nil(message.deleted_at),
          group_by: message.channel_id,
          select: {message.channel_id, count(message.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    Enum.into(threads, %{}, fn thread ->
      {thread.starter_message_id,
       %{
         thread: thread,
         reply_count: Map.get(reply_counts, thread.id, 0)
       }}
    end)
  end

  def get_thread_for_starter_message(%Scope{} = scope, starter_message_id) do
    with {:ok, starter_message_id} <- Ecto.UUID.cast(starter_message_id),
         %Channel{id: id} <- thread_for_starter(starter_message_id) do
      get_thread(scope, id)
    else
      nil -> nil
      :error -> nil
    end
  end

  def get_thread(%Scope{} = scope, thread_id) do
    with {:ok, thread_id} <- Ecto.UUID.cast(thread_id) do
      case Visibility.visible_channel(scope, thread_id) do
        %Channel{} = thread ->
          if Channel.thread?(thread),
            do: Repo.preload(thread, [:parent_channel, starter_message: :author]),
            else: nil

        nil ->
          nil
      end
    else
      :error -> nil
    end
  end

  def create_public_thread(%Scope{} = scope, starter_message_id, attrs \\ %{}) do
    with {:ok, starter_message_id} <- Ecto.UUID.cast(starter_message_id) do
      result =
        Repo.transact(fn ->
          with :ok <-
                 Visibility.authorize_write(scope, :create_public_threads, %Message{
                   id: starter_message_id
                 }),
               %Message{channel_id: parent_id} = starter <- Repo.get(Message, starter_message_id),
               %Channel{} = parent <- Channels.lock_channel(parent_id),
               :ok <- validate_thread_host(parent, starter) do
            case thread_for_starter(starter.id) do
              nil -> insert_thread(scope, parent, starter, attrs)
              existing -> existing_thread(scope, existing.id)
            end
          else
            nil -> {:error, :not_found}
            error -> error
          end
        end)

      case result do
        {:ok, %Channel{} = thread} ->
          Topics.broadcast_guild({:channel_created, thread})
          {:ok, thread}

        other ->
          other
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp invalid_thread_changeset(parent_channel, starter_message, message) do
    starter_message
    |> new_thread(parent_channel, starter_message.author_id)
    |> Channel.thread_changeset(%{})
    |> Ecto.Changeset.add_error(:starter_message_id, message)
  end

  # Everything but the name comes from the starter message and its channel, so a client cannot
  # choose a thread's kind, parent, starter message or creator.
  defp new_thread(starter_message, parent_channel, creator_id) do
    %Channel{
      kind: :thread_public,
      name: thread_name_from_message(starter_message),
      slug: "thread-#{Ecto.UUID.generate()}",
      position: next_thread_position(parent_channel.id),
      parent_channel_id: parent_channel.id,
      starter_message_id: starter_message.id,
      created_by_id: creator_id
    }
  end

  defp thread_name_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, "name", Map.get(attrs, :name)) do
      name when is_binary(name) and name != "" -> %{"name" => name}
      _blank -> %{}
    end
  end

  defp thread_name_attrs(_attrs), do: %{}

  defp thread_name_from_message(%Message{body: body}) do
    body
    |> String.trim()
    |> case do
      "" -> "Thread"
      value -> String.slice(value, 0, 40)
    end
  end

  defp insert_thread(scope, parent, starter, attrs) do
    with {:ok, thread} <-
           starter
           |> new_thread(parent, scope.user_id)
           |> Channel.thread_changeset(thread_name_attrs(attrs))
           |> Repo.insert(),
         :ok <- Channels.ensure_channel_memberships(scope, [thread]) do
      {:ok, Repo.preload(thread, [:parent_channel, starter_message: :author])}
    end
  end

  # A starter that already has a thread answers with that thread, when the scope can view it.
  defp existing_thread(scope, thread_id) do
    case get_thread(scope, thread_id) do
      %Channel{} = thread -> {:ok, thread}
      nil -> {:error, :not_found}
    end
  end

  # authorize_write already refused a deleted starter, so only the parent's kind is left to check.
  defp validate_thread_host(parent, starter) do
    if Channel.thread_host?(parent),
      do: :ok,
      else:
        {:error,
         invalid_thread_changeset(
           parent,
           starter,
           "threads can only start from text-like channels"
         )}
  end

  defp thread_for_starter(starter_id) do
    Repo.one(
      from(channel in Channel,
        where:
          channel.starter_message_id == ^starter_id and channel.kind == :thread_public and
            is_nil(channel.archived_at)
      )
    )
  end

  defp next_thread_position(parent_channel_id) do
    from(channel in Channel,
      where: channel.parent_channel_id == ^parent_channel_id and channel.kind == :thread_public,
      select: max(channel.position)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end
end
