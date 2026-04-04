defmodule Rfchat.Accounts.LoginRateLimiter do
  @moduledoc false

  use GenServer

  alias Rfchat.Ephemeral

  @table :rfchat_login_rate_limiter
  @ip_window_seconds 300
  @ip_limit 20
  @credential_window_seconds 300
  @credential_limit 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def allow_login_attempt(ip_address, email) do
    now = System.system_time(:second)

    login_keys(ip_address, email)
    |> Enum.find_value(:ok, fn {key, limit, _window_seconds} ->
      case bucket_for(key, now) do
        {count, reset_at} when count >= limit -> {:error, max(reset_at - now, 1)}
        _ -> nil
      end
    end)
  end

  def record_failed_attempt(ip_address, email) do
    now = System.system_time(:second)

    Enum.each(login_keys(ip_address, email), fn {key, _limit, window_seconds} ->
      bump_bucket(key, window_seconds, now)
    end)

    :ok
  end

  def clear_attempts(ip_address, email) do
    Enum.each(login_keys(ip_address, email), fn {key, _limit, _window_seconds} ->
      clear_remote_bucket(key)
      :ets.delete(@table, key)
    end)

    :ok
  end

  def reset! do
    :ets.delete_all_objects(@table)

    _ = Ephemeral.clear_rate_limit_namespace(login_rate_limit_prefix())

    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  defp login_keys(ip_address, email) do
    normalized_ip = normalize_ip(ip_address)
    normalized_email = normalize_email(email)

    [
      {{:ip, normalized_ip}, @ip_limit, @ip_window_seconds},
      {{:credential, normalized_ip, normalized_email}, @credential_limit,
       @credential_window_seconds}
    ]
  end

  defp bucket_for(key, now) do
    case remote_bucket(key, now) do
      {:ok, bucket} ->
        bucket

      :unavailable ->
        current_local_bucket(key, now)
    end
  end

  defp current_local_bucket(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, count, reset_at}] when reset_at > now ->
        {count, reset_at}

      [{^key, _count, reset_at}] when reset_at <= now ->
        :ets.delete(@table, key)
        {0, now}

      [] ->
        {0, now}
    end
  end

  defp bump_bucket(key, window_seconds, now) do
    case remote_bump_bucket(key, window_seconds, now) do
      :ok ->
        :ok

      :unavailable ->
        case current_local_bucket(key, now) do
          {0, _reset_at} ->
            :ets.insert(@table, {key, 1, now + window_seconds})

          {count, reset_at} ->
            :ets.insert(@table, {key, count + 1, reset_at})
        end
    end
  end

  defp remote_bucket(key, now) do
    case Ephemeral.get_rate_limit(remote_key(key), now) do
      {:ok, count, reset_at} -> {:ok, {count, reset_at}}
      {:error, :unavailable} -> :unavailable
    end
  end

  defp remote_bump_bucket(key, window_seconds, now) do
    case Ephemeral.increment_rate_limit(remote_key(key), window_seconds, now) do
      {:ok, _count, _reset_at} -> :ok
      {:error, :unavailable} -> :unavailable
    end
  end

  defp clear_remote_bucket(key) do
    _ = Ephemeral.clear_rate_limit(remote_key(key))
    :ok
  end

  defp remote_key(key), do: login_rate_limit_prefix() <> Integer.to_string(:erlang.phash2(key))

  defp login_rate_limit_prefix, do: "rate_limit:login:"

  defp normalize_ip(nil), do: "unknown"
  defp normalize_ip(ip_address) when is_binary(ip_address), do: ip_address
  defp normalize_ip(ip_address), do: ip_address |> :inet.ntoa() |> to_string()

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(_email), do: "unknown"
end
