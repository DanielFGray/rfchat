defmodule Rfchat.Bots.Params do
  @moduledoc false

  alias Rfchat.Accounts
  alias Rfchat.Chat

  def parse_limit(nil), do: 50
  def parse_limit(value) when is_integer(value), do: value |> max(1) |> min(100)

  def parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed |> max(1) |> min(100)
      _ -> 50
    end
  end

  def parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  def parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_params}
    end
  end

  def parse_positive_integer(_), do: {:error, :invalid_params}

  def fetch_channel(channel_id) do
    case Ecto.UUID.cast(channel_id) do
      {:ok, _id} ->
        case Chat.get_channel(channel_id) do
          nil -> {:error, :not_found}
          channel -> {:ok, channel}
        end

      :error ->
        {:error, :invalid_params}
    end
  end

  def fetch_member(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, _id} -> {:ok, Accounts.get_user_with_membership!(user_id)}
      :error -> {:error, :invalid_params}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end
end
