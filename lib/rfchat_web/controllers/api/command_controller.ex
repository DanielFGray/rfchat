defmodule RfchatWeb.API.CommandController do
  use RfchatWeb, :controller

  alias Rfchat.Bots
  alias RfchatWeb.API.ErrorHelpers

  def execute(conn, %{"command" => command_name, "params" => params}) do
    case Bots.execute_command(command_name, conn.assigns.current_bot_scope, params) do
      {:ok, result} ->
        render(conn, :show, result: result)

      {:error, :unknown_command} ->
        ErrorHelpers.render_error(conn, :not_found, "unknown_command", "Unknown bot command.")

      {:error, :not_found} ->
        ErrorHelpers.render_error(
          conn,
          :not_found,
          "not_found",
          "Requested resource was not found."
        )

      {:error, :forbidden} ->
        ErrorHelpers.render_error(
          conn,
          :forbidden,
          "forbidden",
          "Bot lacks permission for that command."
        )

      {:error, :invalid_params} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "invalid_params",
          "Invalid command parameters."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        ErrorHelpers.render_changeset_error(
          conn,
          :unprocessable_entity,
          "invalid_params",
          changeset
        )

      {:error, reason} ->
        ErrorHelpers.render_error(
          conn,
          :unprocessable_entity,
          "command_failed",
          to_string(reason)
        )
    end
  end
end
