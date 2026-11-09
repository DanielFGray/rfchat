defmodule RfchatWeb.Plugs.ClientIpTest do
  use ExUnit.Case, async: false

  alias RfchatWeb.Plugs.ClientIp

  setup do
    previous = Application.get_env(:rfchat, :trusted_proxy_header)
    on_exit(fn -> Application.put_env(:rfchat, :trusted_proxy_header, previous) end)
    :ok
  end

  test "client_ip/2 returns the peer address for a missing or invalid header" do
    Application.put_env(:rfchat, :trusted_proxy_header, "x-forwarded-for")
    peer_ip = {127, 0, 0, 1}

    assert ClientIp.client_ip(peer_ip, []) == peer_ip
    assert ClientIp.client_ip(peer_ip, [{"x-forwarded-for", "not-an-ip"}]) == peer_ip
  end

  test "leaves remote_ip unchanged when the header is not configured" do
    Application.delete_env(:rfchat, :trusted_proxy_header)
    conn = ClientIp.call(%Plug.Conn{remote_ip: {127, 0, 0, 1}}, [])
    assert conn.remote_ip == {127, 0, 0, 1}
  end

  test "uses the leftmost forwarded IPv4 address" do
    Application.put_env(:rfchat, :trusted_proxy_header, "x-forwarded-for")

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-for", "100.64.1.2, 192.168.1.5")
      |> ClientIp.call([])

    assert conn.remote_ip == {100, 64, 1, 2}
  end

  test "matches a configured header name written in any case" do
    Application.put_env(:rfchat, :trusted_proxy_header, "X-Real-Ip")

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-real-ip", "203.0.113.7")
      |> ClientIp.call([])

    assert conn.remote_ip == {203, 0, 113, 7}
  end

  test "parses IPv6 addresses" do
    Application.put_env(:rfchat, :trusted_proxy_header, "x-forwarded-for")

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-for", "2001:db8::1, 2001:db8::2")
      |> ClientIp.call([])

    assert conn.remote_ip == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
  end

  test "leaves remote_ip unchanged when the header is invalid" do
    Application.put_env(:rfchat, :trusted_proxy_header, "x-forwarded-for")

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_req_header("x-forwarded-for", "not-an-ip")
      |> ClientIp.call([])

    assert conn.remote_ip == {127, 0, 0, 1}
  end
end
