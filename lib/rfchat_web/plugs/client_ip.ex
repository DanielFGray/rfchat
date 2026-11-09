defmodule RfchatWeb.Plugs.ClientIp do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Application.get_env(:rfchat, :trusted_proxy_header) do
      nil -> conn
      header -> set_client_ip(conn, header)
    end
  end

  # Plug.Conn stores request header names in lowercase, and the platform docs spell them
  # either way (`x-real-ip`, `X-Forwarded-For`).
  defp set_client_ip(conn, header) do
    case get_req_header(conn, String.downcase(header)) do
      [value | _] ->
        value
        |> String.split(",", parts: 2)
        |> hd()
        |> String.trim()
        |> String.to_charlist()
        |> :inet.parse_address()
        |> case do
          {:ok, ip_address} -> %{conn | remote_ip: ip_address}
          {:error, _reason} -> conn
        end

      [] ->
        conn
    end
  end
end
