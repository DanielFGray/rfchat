defmodule RfchatWeb.TestSupportController do
  use RfchatWeb, :controller

  alias Rfchat.TestSupport

  def command(conn, params) do
    ensure_enabled!()

    command = params["command"] || raise "command is required"
    payload = decode_payload(params["payload"])

    case TestSupport.run_command(command, payload, conn) do
      {:json, data} ->
        json(conn, %{data: data})

      {:conn, conn} ->
        # The command handled the response itself (e.g. login redirect).
        conn
    end
  rescue
    error ->
      conn
      |> put_status(:internal_server_error)
      |> json(%{
        error: %{
          message: Exception.message(error),
          stack: Exception.format_stacktrace(__STACKTRACE__)
        }
      })
  end

  defp ensure_enabled! do
    unless test_support_enabled?() do
      raise "test support commands are disabled"
    end

    if Application.get_env(:rfchat, :env) == :prod do
      raise "test support commands must never run in production"
    end
  end

  defp test_support_enabled? do
    Application.get_env(:rfchat, :env) in [:dev, :test] and
      System.get_env("ENABLE_TEST_SUPPORT_COMMANDS") == "1"
  end

  defp decode_payload(nil), do: %{}
  defp decode_payload(""), do: %{}

  defp decode_payload(payload) when is_binary(payload) do
    Jason.decode!(payload)
  end
end
