defmodule Rfchat.Chat.Threads do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.Permissions
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  @channel_events_topic "chat:channels"

  def list_thread_messages(channel_or_id, opts \\ [])

  def list_thread_messages(%Channel{id: channel_id}, opts),
    do: list_thread_messages(channel_id, opts)

  def list_thread_messages(channel_id, opts) do
    limit = Keyword.get(opts, :limit, 50)

    Message
    |> where([message], message.channel_id == ^channel_id)
    |> where([message], is_nil(message.deleted_at))
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(^limit)
    |> preload([:author, reactions: [emoji: :asset], reply_to: :author])
    |> Repo.all()
    |> Enum.reverse()
  end

  def list_threads_for_channel(channel_id) do
    Channel
    |> where(
      [channel],
      channel.parent_channel_id == ^channel_id and channel.kind == :thread_public and
        is_nil(channel.archived_at)
    )
    |> order_by([channel], asc: channel.inserted_at, asc: channel.id)
    |> preload([:parent_channel, starter_message: :author])
    |> Repo.all()
  end

  def thread_summaries_for_channel(channel_id) do
    threads = list_threads_for_channel(channel_id)
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

  def get_thread_for_starter_message(starter_message_id) do
    Channel
    |> where(
      [channel],
      channel.starter_message_id == ^starter_message_id and channel.kind == :thread_public and
        is_nil(channel.archived_at)
    )
    |> preload([:parent_channel, starter_message: :author])
    |> Repo.one()
  end

  def get_thread_for_user(thread_id, %User{} = user) do
    thread = Repo.get(Channel, thread_id)

    cond do
      is_nil(thread) ->
        {:error, :not_found}

      not Permissions.thread_channel?(thread) ->
        {:error, :not_found}

      Permissions.can_view_channel?(thread, user) ->
        {:ok, Repo.preload(thread, [:parent_channel, starter_message: :author])}

      true ->
        {:error, :forbidden}
    end
  end

  def create_public_thread(
        %Channel{} = parent_channel,
        %Message{} = starter_message,
        %User{} = author,
        attrs \\ %{}
      ) do
    parent_channel = Repo.preload(parent_channel, [:permission_overwrites])
    author = Repo.preload(author, [:membership, member_roles: :role])
    starter_message = Repo.preload(starter_message, [:author, :channel])

    with :ok <- authorize_public_thread_create(parent_channel, starter_message, author) do
      case get_thread_for_starter_message(starter_message.id) do
        %Channel{} = thread ->
          {:ok, thread}

        nil ->
          attrs = normalize_thread_attrs(attrs, starter_message, parent_channel)

          Repo.transaction(fn ->
            with {:ok, thread} <-
                   %Channel{created_by_id: author.id}
                   |> Channel.changeset(attrs)
                   |> Repo.insert() do
              :ok = Rfchat.Chat.ensure_channel_memberships_for_user(author, [thread])
              Repo.preload(thread, [:parent_channel, starter_message: :author])
            else
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)
          |> case do
            {:ok, thread} ->
              broadcast({:channel_created, thread})
              {:ok, thread}

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    end
  end

  def normalize_thread_attrs(attrs, starter_message, parent_channel) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    parent_channel = parent_channel || starter_message.channel

    attrs
    |> Map.put_new("name", thread_name_from_message(starter_message))
    |> Map.put_new("slug", "thread-#{Ecto.UUID.generate()}")
    |> Map.put_new("kind", :thread_public)
    |> Map.put_new("position", next_thread_position(parent_channel.id))
    |> Map.put_new("parent_channel_id", parent_channel.id)
    |> Map.put_new("starter_message_id", starter_message.id)
    |> Map.put_new("topic", nil)
  end

  def invalid_thread_changeset(parent_channel, starter_message, message) do
    %Channel{created_by_id: starter_message.author_id}
    |> Channel.changeset(normalize_thread_attrs(%{}, starter_message, parent_channel))
    |> Ecto.Changeset.add_error(:starter_message_id, message)
  end

  def thread_name_from_message(%Message{body: body}) do
    body
    |> String.trim()
    |> case do
      "" -> "Thread"
      value -> String.slice(value, 0, 40)
    end
  end

  def next_thread_position(parent_channel_id) do
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

  def authorize_public_thread_create(
        %Channel{} = parent_channel,
        %Message{} = starter_message,
        %User{} = author
      ) do
    cond do
      starter_message.channel_id != parent_channel.id ->
        {:error,
         invalid_thread_changeset(
           parent_channel,
           starter_message,
           "starter message must belong to that channel"
         )}

      not Permissions.thread_host_channel?(parent_channel) ->
        {:error,
         invalid_thread_changeset(
           parent_channel,
           starter_message,
           "threads can only start from text-like channels"
         )}

      not Permissions.can_create_public_threads?(parent_channel, author) ->
        {:error, :forbidden}

      deleted_message?(starter_message) ->
        {:error,
         invalid_thread_changeset(
           parent_channel,
           starter_message,
           "cannot start a thread from a deleted message"
         )}

      true ->
        :ok
    end
  end

  def deleted_message?(%Message{} = message) do
    not is_nil(message.deleted_at) or Map.get(message.metadata || %{}, "deleted", false)
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast_from(Rfchat.PubSub, self(), @channel_events_topic, message)
  end
end
