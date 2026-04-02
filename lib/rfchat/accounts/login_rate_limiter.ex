defmodule Rfchat.Accounts.LoginRateLimiter do
  @moduledoc false

  use GenServer

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
      case current_bucket(key, now) do
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
      :ets.delete(@table, key)
    end)

    :ok
  end

  def reset! do
    :ets.delete_all_objects(@table)
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

  defp current_bucket(key, now) do
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
    case current_bucket(key, now) do
      {0, _reset_at} ->
        :ets.insert(@table, {key, 1, now + window_seconds})

      {count, reset_at} ->
        :ets.insert(@table, {key, count + 1, reset_at})
    end
  end

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
