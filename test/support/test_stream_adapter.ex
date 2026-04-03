defmodule RfchatWeb.TestStreamAdapter do
  @moduledoc false

  @behaviour Plug.Conn.Adapter

  def wrap(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, payload}} = conn) do
    {%{conn | adapter: {__MODULE__, payload}}, Map.fetch!(payload, :ref)}
  end

  def send_resp(payload, status, headers, body) do
    Plug.Adapters.Test.Conn.send_resp(payload, status, headers, body)
  end

  def send_file(payload, status, headers, file, offset, length) do
    Plug.Adapters.Test.Conn.send_file(payload, status, headers, file, offset, length)
  end

  def send_chunked(payload, status, headers) do
    Plug.Adapters.Test.Conn.send_chunked(payload, status, headers)
  end

  def chunk(%{owner: owner, ref: ref} = payload, body) do
    case Plug.Adapters.Test.Conn.chunk(payload, body) do
      {:ok, _sent_body, _payload} = ok ->
        send(owner, {ref, :chunk, IO.iodata_to_binary(body)})
        ok

      other ->
        other
    end
  end

  def read_req_body(payload, options) do
    Plug.Adapters.Test.Conn.read_req_body(payload, options)
  end

  def push(payload, path, headers) do
    Plug.Adapters.Test.Conn.push(payload, path, headers)
  end

  def inform(payload, _status, _headers) do
    _ = payload
    {:error, :not_supported}
  end

  def upgrade(payload, _protocol, _opts) do
    _ = payload
    {:error, :not_supported}
  end

  def get_peer_data(payload) do
    Plug.Adapters.Test.Conn.get_peer_data(payload)
  end

  def get_sock_data(payload) do
    Plug.Adapters.Test.Conn.get_sock_data(payload)
  end

  def get_ssl_data(payload) do
    Plug.Adapters.Test.Conn.get_ssl_data(payload)
  end

  def get_http_protocol(payload) do
    Plug.Adapters.Test.Conn.get_http_protocol(payload)
  end
end
