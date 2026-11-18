defmodule Tavern.Bots.Params do
  @moduledoc false

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

  @doc "A malformed channel id is an invalid request; a well-formed one goes to the scoped operation."
  def channel_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_params}
    end
  end

  @doc "A malformed member id is an invalid request; a well-formed one is decided by the scoped operation."
  def member_id(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_params}
    end
  end
end
