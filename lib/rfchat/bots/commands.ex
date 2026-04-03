defmodule Rfchat.Bots.Commands do
  @moduledoc false

  alias Rfchat.Bots.BotScope
  alias Rfchat.Bots.Params
  alias Rfchat.Bots.Serializer
  alias Rfchat.Chat

  @command_registry %{
    "send_message" => &__MODULE__.send_message/2,
    "list_messages" => &__MODULE__.list_messages/2,
    "timeout_member" => &__MODULE__.timeout_member/2,
    "kick_member" => &__MODULE__.kick_member/2,
    "ban_member" => &__MODULE__.ban_member/2
  }

  def command_registry, do: @command_registry

  def execute(command_name, %BotScope{} = scope, params) when is_map(params) do
    case Map.fetch(@command_registry, command_name) do
      {:ok, handler} -> handler.(scope, params)
      :error -> {:error, :unknown_command}
    end
  end

  def send_message(
        %BotScope{bot_user: bot_user},
        %{"channel_id" => channel_id, "body" => body} = params
      ) do
    with {:ok, channel} <- Params.fetch_channel(channel_id) do
      attrs =
        params
        |> Map.take(["body", "metadata", "reply_to_id"])
        |> Map.put("body", body)

      case Chat.create_message(channel, bot_user, attrs) do
        {:ok, message} -> {:ok, %{message: Serializer.serialize_message(message)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def send_message(_, _), do: {:error, :invalid_params}

  def list_messages(%BotScope{bot_user: bot_user}, %{"channel_id" => channel_id} = params) do
    with {:ok, channel} <- Params.fetch_channel(channel_id) do
      if Chat.can_view_channel?(channel, bot_user) do
        limit = Params.parse_limit(Map.get(params, "limit"))
        messages = Chat.list_messages(channel.id, limit: limit)
        {:ok, %{messages: Enum.map(messages, &Serializer.serialize_message/1)}}
      else
        {:error, :forbidden}
      end
    end
  end

  def list_messages(_, _), do: {:error, :invalid_params}

  def timeout_member(%BotScope{bot_user: bot_user}, %{"user_id" => user_id} = params) do
    with {:ok, subject} <- Params.fetch_member(user_id),
         {:ok, duration_minutes} <-
           Params.parse_positive_integer(Map.get(params, "duration_minutes")) do
      case Chat.timeout_member(bot_user, subject, duration_minutes, Map.get(params, "reason")) do
        {:ok, updated_subject, moderation_case} ->
          {:ok, Serializer.moderation_response(updated_subject, moderation_case, "timeout")}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def timeout_member(_, _), do: {:error, :invalid_params}

  def kick_member(%BotScope{bot_user: bot_user}, %{"user_id" => user_id} = params) do
    with {:ok, subject} <- Params.fetch_member(user_id) do
      case Chat.kick_member(bot_user, subject, Map.get(params, "reason")) do
        {:ok, updated_subject, moderation_case} ->
          {:ok, Serializer.moderation_response(updated_subject, moderation_case, "kick")}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def kick_member(_, _), do: {:error, :invalid_params}

  def ban_member(%BotScope{bot_user: bot_user}, %{"user_id" => user_id} = params) do
    with {:ok, subject} <- Params.fetch_member(user_id) do
      case Chat.ban_member(bot_user, subject, Map.get(params, "reason")) do
        {:ok, updated_subject, moderation_case} ->
          {:ok, Serializer.moderation_response(updated_subject, moderation_case, "ban")}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def ban_member(_, _), do: {:error, :invalid_params}
end
