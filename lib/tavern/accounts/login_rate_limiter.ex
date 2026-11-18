defmodule Tavern.Accounts.LoginRateLimiter do
  @moduledoc false

  use GenServer

  alias Tavern.Ephemeral

  @table :tavern_login_rate_limiter
  @ip_window_seconds 300
  @ip_limit 20
  @credential_window_seconds 300
  @credential_limit 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check_attempt(ip_address, email) do
    now = System.system_time(:second)

    retry_after =
      Enum.reduce(login_keys(ip_address, email), nil, fn {key, limit, window_seconds},
                                                         retry_after ->
        {count, reset_at} = bump_bucket(key, window_seconds, now)

        if count > limit do
          max(retry_after || 0, max(reset_at - now, 1))
        else
          retry_after
        end
      end)

    case retry_after do
      nil -> :ok
      seconds -> {:error, seconds}
    end
  end

  def clear_attempts(ip_address, email) do
    key = credential_key(ip_address, email)
    clear_remote_bucket(key)
    :ets.delete(@table, key)

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
      {credential_key(normalized_ip, normalized_email), @credential_limit,
       @credential_window_seconds}
    ]
  end

  defp credential_key(ip_address, email) do
    {:credential, normalize_ip(ip_address), normalize_email(email)}
  end

  defp bump_bucket(key, window_seconds, now) do
    case remote_bump_bucket(key, window_seconds, now) do
      {:ok, count, reset_at} ->
        {count, reset_at}

      :unavailable ->
        local_bump_bucket(key, window_seconds, now)
    end
  end

  # Each step is one atomic ets call: the delete removes only a window that has ended, and
  # update_counter inserts a fresh window when the row is missing, so concurrent callers never
  # read a row that another caller deletes.
  defp local_bump_bucket(key, window_seconds, now) do
    :ets.select_delete(@table, [{{key, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])

    [count, reset_at] =
      :ets.update_counter(@table, key, [{2, 1}, {3, 0}], {key, 0, now + window_seconds})

    {count, reset_at}
  end

  defp remote_bump_bucket(key, window_seconds, now) do
    case Ephemeral.increment_rate_limit(remote_key(key), window_seconds, now) do
      {:ok, count, reset_at} -> {:ok, count, reset_at}
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
