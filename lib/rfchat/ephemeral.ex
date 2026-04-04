defmodule Rfchat.Ephemeral do
  @moduledoc false

  @presence_prefix "presence:user:"
  @typing_prefix "typing:channel:"

  alias Rfchat.Redis

  @presence_online_ttl 300
  @presence_recent_ttl 3600
  @typing_ttl 8

  def presence_online_ttl, do: @presence_online_ttl
  def presence_recent_ttl, do: @presence_recent_ttl
  def typing_ttl, do: @typing_ttl

  def heartbeat_presence(user_id, now \\ DateTime.utc_now()) when is_binary(user_id) do
    timestamp = DateTime.to_unix(now, :second)

    case Redis.command(["SET", presence_key(user_id), Integer.to_string(timestamp), "EX", "3600"]) do
      {:ok, "OK"} -> :ok
      {:error, _reason} -> :error
    end
  end

  def get_presence_timestamps(user_ids) when is_list(user_ids) do
    keys = Enum.map(user_ids, &presence_key/1)

    case keys do
      [] -> %{}
      _ -> parse_presence_timestamps(user_ids, Redis.command(["MGET" | keys]))
    end
  end

  def put_typing(channel_id, user_id, now \\ DateTime.utc_now())
      when is_binary(channel_id) and is_binary(user_id) do
    timestamp = DateTime.to_unix(now, :second)
    key = typing_key(channel_id)

    case Redis.pipeline([
           ["ZADD", key, Integer.to_string(timestamp), user_id],
           ["EXPIRE", key, Integer.to_string(@typing_ttl)]
         ]) do
      {:ok, _results} -> :ok
      {:error, _reason} -> :error
    end
  end

  def remove_typing(channel_id, user_id) when is_binary(channel_id) and is_binary(user_id) do
    case Redis.command(["ZREM", typing_key(channel_id), user_id]) do
      {:ok, _removed} -> :ok
      {:error, _reason} -> :error
    end
  end

  def list_typing_user_ids(channel_id, now \\ DateTime.utc_now()) when is_binary(channel_id) do
    min_score = DateTime.add(now, -@typing_ttl, :second) |> DateTime.to_unix(:second)

    case Redis.command([
           "ZRANGEBYSCORE",
           typing_key(channel_id),
           Integer.to_string(min_score),
           "+inf"
         ]) do
      {:ok, user_ids} -> user_ids
      {:error, _reason} -> []
    end
  end

  def increment_rate_limit(key, window_seconds, now \\ System.system_time(:second))
      when is_binary(key) and is_integer(window_seconds) do
    expires_at = now + window_seconds

    case Redis.pipeline([
           ["INCR", key],
           ["EXPIRE", key, Integer.to_string(window_seconds)],
           ["TTL", key]
         ]) do
      {:ok, [count, _expire, ttl]} when is_integer(count) and is_integer(ttl) ->
        {:ok, count, now + max(ttl, 0)}

      {:ok, [count, _expire, -1]} when is_integer(count) ->
        {:ok, count, expires_at}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  def get_rate_limit(key, now \\ System.system_time(:second)) when is_binary(key) do
    case Redis.pipeline([["GET", key], ["TTL", key]]) do
      {:ok, [nil, _ttl]} -> {:ok, 0, now}
      {:ok, [count, ttl]} -> {:ok, String.to_integer(count), now + max(ttl, 0)}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  def clear_rate_limit(key) when is_binary(key) do
    case Redis.command(["DEL", key]) do
      {:ok, _deleted} -> :ok
      {:error, _reason} -> :error
    end
  end

  def clear_rate_limit_namespace(prefix) when is_binary(prefix) do
    case Redis.command(["KEYS", prefix <> "*"]) do
      {:ok, []} ->
        :ok

      {:ok, keys} ->
        _ = Redis.command(["DEL" | keys])
        :ok

      {:error, _reason} ->
        :error
    end
  end

  defp parse_presence_timestamps(user_ids, {:ok, values}) do
    user_ids
    |> Enum.zip(values)
    |> Enum.reduce(%{}, fn
      {user_id, value}, acc when is_binary(value) ->
        Map.put(acc, user_id, DateTime.from_unix!(String.to_integer(value)))

      {_user_id, _value}, acc ->
        acc
    end)
  end

  defp parse_presence_timestamps(_user_ids, {:error, _reason}), do: %{}

  defp presence_key(user_id), do: @presence_prefix <> user_id
  defp typing_key(channel_id), do: @typing_prefix <> channel_id
end
