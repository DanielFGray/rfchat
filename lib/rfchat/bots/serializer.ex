defmodule Rfchat.Bots.Serializer do
  @moduledoc false

  alias Ecto.Association.NotLoaded
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  def serialize_bot_user(%User{} = bot_user) do
    serialize_user(bot_user)
    |> Map.merge(%{
      email: bot_user.email,
      bio: bot_user.bio,
      role_ids: Enum.map(bot_user.member_roles || [], & &1.role_id),
      inserted_at: bot_user.inserted_at
    })
  end

  def serialize_user(%User{} = user) do
    %{
      id: user.id,
      username: user.username,
      display_name: user.display_name,
      bot: user.bot,
      system: user.system
    }
  end

  def serialize_message(%Message{} = message) do
    message =
      Repo.preload(message, [
        :author,
        channel: [:parent_channel, starter_message: :author],
        reply_to: :author
      ])

    %{
      id: message.id,
      channel_id: message.channel_id,
      author_id: message.author_id,
      reply_to_id: message.reply_to_id,
      body: message.body,
      kind: to_string(message.kind),
      metadata: message.metadata || %{},
      inserted_at: message.inserted_at,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      author: serialize_loaded_user(message.author),
      channel: serialize_channel_summary(message.channel),
      reply_to: serialize_message_reference(message.reply_to)
    }
  end

  def serialize_thread(%Channel{} = thread) do
    thread = Repo.preload(thread, [:parent_channel, starter_message: :author])

    serialize_channel_summary(thread)
    |> Map.merge(%{
      parent_channel: serialize_channel_summary(thread.parent_channel),
      starter_message: serialize_message_reference(thread.starter_message)
    })
  end

  def moderation_response(updated_subject, moderation_case, action) do
    %{
      subject_user_id: updated_subject.id,
      moderation_case_id: moderation_case.id,
      action: action
    }
  end

  defp serialize_channel_summary(%Channel{} = channel) do
    %{
      id: channel.id,
      name: channel.name,
      slug: channel.slug,
      kind: to_string(channel.kind),
      topic: channel.topic,
      parent_channel_id: channel.parent_channel_id,
      starter_message_id: channel.starter_message_id,
      inserted_at: channel.inserted_at,
      archived_at: channel.archived_at,
      locked_at: channel.locked_at
    }
  end

  defp serialize_channel_summary(%NotLoaded{}), do: nil
  defp serialize_channel_summary(nil), do: nil

  defp serialize_message_reference(%Message{} = message) do
    message = Repo.preload(message, [:author])

    %{
      id: message.id,
      channel_id: message.channel_id,
      author_id: message.author_id,
      reply_to_id: message.reply_to_id,
      body: message.body,
      kind: to_string(message.kind),
      metadata: message.metadata || %{},
      inserted_at: message.inserted_at,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at,
      author: serialize_loaded_user(message.author)
    }
  end

  defp serialize_message_reference(%NotLoaded{}), do: nil
  defp serialize_message_reference(nil), do: nil

  defp serialize_loaded_user(%User{} = user), do: serialize_user(user)
  defp serialize_loaded_user(%NotLoaded{}), do: nil
  defp serialize_loaded_user(nil), do: nil
end
