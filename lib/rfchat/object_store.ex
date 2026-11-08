defmodule Rfchat.ObjectStore do
  @moduledoc """
  The S3 bucket that holds uploaded files.

  Requests use path-style addressing (`endpoint/bucket/key`) and AWS Signature Version 4.
  The platform's store has no public route, so the app serves objects through its own
  `/uploads` route. A staged copy uses the live bucket with its own key, and its database
  rows name live objects: a delete in a staged copy removes the live object. The
  configuration comes from the environment. See `config/runtime.exs`.

  Configuration under `config :rfchat, Rfchat.ObjectStore`:

    * `:endpoint`, `:bucket`, `:region`, `:access_key_id`, `:secret_access_key`
    * `:req_options` - extra `Req` options. Tests set `plug:` here to keep the bucket in
      memory; every other step, such as signing, still runs.
  """

  @doc "Stores `body` at `key`."
  def put(key, body, content_type) when is_binary(key) and is_binary(body) do
    case request(:put, key, body: body, headers: [{"content-type", content_type}]) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  @doc "The object at `key`, as `{:ok, body, content_type}`, or `{:error, :not_found}`."
  def get(key) when is_binary(key) do
    case request(:get, key) do
      {:ok, %Req.Response{status: 200, body: body} = response} ->
        {:ok, body, response |> Req.Response.get_header("content-type") |> List.first()}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      other ->
        error(other)
    end
  end

  @doc "Removes the object at `key`. Removing a missing object succeeds."
  def delete(key) when is_binary(key) do
    case request(:delete, key) do
      {:ok, %Req.Response{status: status}} when status in [200, 204, 404] -> :ok
      other -> error(other)
    end
  end

  defp request(method, key, options \\ []) do
    config = Application.fetch_env!(:rfchat, __MODULE__)

    [
      method: method,
      url: object_url(config, key),
      aws_sigv4: [
        service: :s3,
        region: Keyword.fetch!(config, :region),
        access_key_id: Keyword.fetch!(config, :access_key_id),
        secret_access_key: Keyword.fetch!(config, :secret_access_key)
      ],
      # PUT and DELETE of one key are idempotent, so every method may retry a transient fault.
      retry: :transient,
      decode_body: false
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.merge(options)
    |> Req.request()
  end

  defp object_url(config, key) do
    segments = [Keyword.fetch!(config, :bucket) | String.split(key, "/")]

    path =
      Enum.map_join(segments, "/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    String.trim_trailing(Keyword.fetch!(config, :endpoint), "/") <> "/" <> path
  end

  defp error({:ok, %Req.Response{status: status}}), do: {:error, {:object_store, status}}
  defp error({:error, exception}), do: {:error, {:object_store, exception}}
end
