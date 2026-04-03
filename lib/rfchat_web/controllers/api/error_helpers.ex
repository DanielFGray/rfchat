defmodule RfchatWeb.API.ErrorHelpers do
  @moduledoc false

  import Ecto.Changeset
  import Plug.Conn
  import Phoenix.Controller

  def render_error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
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
