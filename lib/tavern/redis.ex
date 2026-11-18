defmodule Tavern.Redis do
  @moduledoc false

  @name __MODULE__

  def child_spec(opts \\ []) do
    url = Keyword.get(opts, :url, Application.fetch_env!(:tavern, :valkey_url))

    %{
      id: @name,
      start: {Redix, :start_link, [url, [name: @name, sync_connect: false]]}
    }
  end

  def command(args, opts \\ []) when is_list(args) do
    case Process.whereis(@name) do
      nil -> {:error, :unavailable}
      _pid -> Redix.command(@name, args, opts)
    end
  end

  def pipeline(args, opts \\ []) when is_list(args) do
    case Process.whereis(@name) do
      nil -> {:error, :unavailable}
      _pid -> Redix.pipeline(@name, args, opts)
    end
  end
end
