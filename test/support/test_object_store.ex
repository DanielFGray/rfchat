defmodule Rfchat.TestObjectStore do
  @moduledoc """
  An in-memory S3 bucket for the test environment, used as `Rfchat.ObjectStore`'s Req
  `plug:` transport. It answers PUT, GET and DELETE on object paths.

  The bucket is a named Agent that the first request starts, unlinked, so it outlives
  whichever process asked first. ExUnit and the e2e server (also `MIX_ENV=test`) both get
  it without a start call.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(options), do: options

  @impl true
  def call(%Plug.Conn{method: "PUT", request_path: path} = conn, _options) do
    {:ok, body, conn} = read_body(conn, length: 50_000_000)
    content_type = conn |> get_req_header("content-type") |> List.first()
    Agent.update(bucket(), &Map.put(&1, path, {body, content_type}))
    send_resp(conn, 200, "")
  end

  def call(%Plug.Conn{method: "GET", request_path: path} = conn, _options) do
    case Agent.get(bucket(), &Map.fetch(&1, path)) do
      {:ok, {body, content_type}} ->
        conn |> put_resp_content_type(content_type, nil) |> send_resp(200, body)

      :error ->
        send_resp(conn, 404, "")
    end
  end

  def call(%Plug.Conn{method: "DELETE", request_path: path} = conn, _options) do
    Agent.update(bucket(), &Map.delete(&1, path))
    send_resp(conn, 204, "")
  end

  defp bucket do
    case Agent.start(fn -> %{} end, name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
