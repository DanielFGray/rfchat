defmodule RfchatWeb.API.BotController do
  use RfchatWeb, :controller

  alias Rfchat.Bots
  alias Rfchat.Bots.BotScope
  alias Rfchat.Chat
  alias Rfchat.Chat.BotToken
  alias Rfchat.Repo
  alias RfchatWeb.API.ErrorHelpers

  def index(conn, _params) do
    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      json(conn, RfchatWeb.API.BotJSON.index(%{bots: Bots.list_bot_users()}))
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def create(conn, %{"bot" => bot_params}) do
    actor = conn.assigns.current_user

    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      case Bots.create_bot(bot_params, actor) do
        {:ok, bot} ->
          conn
          |> put_status(:created)
          |> json(RfchatWeb.API.BotJSON.show(%{bot: bot}))

        {:error, changeset} ->
          ErrorHelpers.render_changeset_error(
            conn,
            :unprocessable_entity,
            "invalid_bot",
            changeset
          )
      end
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def update(conn, %{"id" => id, "bot" => bot_params}) do
    actor = conn.assigns.current_user

    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      case Bots.get_bot_user(id) do
        nil ->
          ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot not found.")

        bot ->
          case Bots.update_bot(bot, bot_params, actor) do
            {:ok, updated_bot} ->
              json(conn, RfchatWeb.API.BotJSON.show(%{bot: updated_bot}))

            {:error, changeset} ->
              ErrorHelpers.render_changeset_error(
                conn,
                :unprocessable_entity,
                "invalid_bot",
                changeset
              )
          end
      end
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def delete(conn, %{"id" => id}) do
    actor = conn.assigns.current_user

    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      case Bots.get_bot_user(id) do
        nil ->
          ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot not found.")

        bot ->
          case Bots.revoke_bot(bot, actor) do
            {:ok, revoked_bot} ->
              json(conn, RfchatWeb.API.BotJSON.show(%{bot: revoked_bot}))

            {:error, _reason} ->
              ErrorHelpers.render_error(
                conn,
                :unprocessable_entity,
                "invalid_bot",
                "Unable to revoke bot."
              )
          end
      end
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def create_token(conn, %{"id" => id, "token" => token_params}) do
    actor = conn.assigns.current_user

    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      case Bots.get_bot_user(id) do
        nil ->
          ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot not found.")

        bot ->
          case Bots.create_bot_token(bot, token_params, actor) do
            {:ok, token_info} ->
              conn
              |> put_status(:created)
              |> json(RfchatWeb.API.BotJSON.token(%{bot: bot, token: token_info}))

            {:error, changeset} ->
              ErrorHelpers.render_changeset_error(
                conn,
                :unprocessable_entity,
                "invalid_bot_token",
                changeset
              )
          end
      end
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def list_tokens(conn, %{"id" => id}) do
    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      case Bots.get_bot_user(id) do
        nil ->
          ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot not found.")

        bot ->
          json(conn, RfchatWeb.API.BotJSON.tokens(%{tokens: Bots.list_bot_tokens(bot)}))
      end
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def revoke_token(conn, %{"id" => id}) do
    actor = conn.assigns.current_user

    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      token = Repo.get(BotToken, id)

      case token && Bots.revoke_bot_token(token, actor) do
        {:ok, revoked_token} ->
          json(conn, %{data: %{id: revoked_token.id, revoked_at: revoked_token.revoked_at}})

        _ ->
          ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot token not found.")
      end
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def events(conn, _params) do
    %BotScope{bot_user: bot_user} = conn.assigns.current_bot_scope

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    :ok = Phoenix.PubSub.subscribe(Rfchat.PubSub, "chat:channels")
    initial = "event: ready\ndata: #{Jason.encode!(%{bot_id: bot_user.id})}\n\n"
    {:ok, conn} = chunk(conn, initial)
    stream_events(conn, bot_user)
  end

  defp stream_events(conn, bot_user) do
    receive do
      {:message_created, message} ->
        conn = maybe_chunk_event(conn, bot_user, "message.created", message)
        stream_events(conn, bot_user)

      {:message_updated, message} ->
        conn = maybe_chunk_event(conn, bot_user, "message.updated", message)
        stream_events(conn, bot_user)

      {:message_deleted, message} ->
        conn = maybe_chunk_event(conn, bot_user, "message.deleted", message)
        stream_events(conn, bot_user)

      _other ->
        stream_events(conn, bot_user)
    after
      20_000 ->
        {:ok, conn} = chunk(conn, ": keepalive\n\n")
        stream_events(conn, bot_user)
    end
  end

  defp maybe_chunk_event(conn, bot_user, event_name, message) do
    channel = Chat.get_channel!(message.channel_id)

    if Chat.can_view_channel?(channel, bot_user) do
      payload = Jason.encode!(Bots.serialize_message(message))

      case chunk(conn, "event: #{event_name}\ndata: #{payload}\n\n") do
        {:ok, conn} -> conn
        {:error, _reason} -> conn
      end
    else
      conn
    end
  end
end
