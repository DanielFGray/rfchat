defmodule TavernWeb.API.ErrorHelpers do
  @moduledoc false

  import Ecto.Changeset
  import Plug.Conn
  import Phoenix.Controller

  def render_error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  @doc "422 for a request whose body is missing its expected key or is not a JSON object."
  def render_invalid_body(conn) do
    render_error(
      conn,
      :unprocessable_entity,
      "invalid_params",
      "Request body is missing the expected object."
    )
  end

  @doc "429 for a send refused by slowmode, with the wait in `retry_after` seconds."
  def render_slowmode(conn, seconds_left) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds_left))
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        code: "slowmode",
        message: "Slowmode is on. Wait #{seconds_left}s before sending again.",
        retry_after: seconds_left
      }
    })
  end

  def render_changeset_error(conn, status, code, changeset, message \\ "Validation failed.") do
    conn
    |> put_status(status)
    |> json(%{
      error: %{
        code: code,
        message: message,
        details:
          traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)
      }
    })
  end
end
