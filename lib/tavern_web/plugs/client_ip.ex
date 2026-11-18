defmodule TavernWeb.Plugs.ClientIp do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    %{conn | remote_ip: client_ip(conn.remote_ip, conn.req_headers)}
  end

  @doc """
  The client address for a request: the leftmost entry of the header that TRUSTED_PROXY_HEADER
  names, or the peer address when that header is unset, missing or not an address. `headers` are
  `{name, value}` pairs with lowercase names, as Plug and Phoenix connect_info give them.
  """
  def client_ip(peer_ip, headers) do
    case Application.get_env(:tavern, :trusted_proxy_header) do
      nil -> peer_ip
      header -> forwarded_ip(peer_ip, headers, String.downcase(header))
    end
  end

  defp forwarded_ip(peer_ip, headers, trusted_header) do
    case List.keyfind(headers, trusted_header, 0) do
      {_name, value} ->
        value
        |> String.split(",", parts: 2)
        |> hd()
        |> String.trim()
        |> String.to_charlist()
        |> :inet.parse_address()
        |> case do
          {:ok, ip_address} -> ip_address
          {:error, _reason} -> peer_ip
        end

      nil ->
        peer_ip
    end
  end
end
