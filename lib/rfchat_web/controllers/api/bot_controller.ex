defmodule RfchatWeb.API.BotController do
  use RfchatWeb, :controller

  alias Rfchat.Accounts.Scope
  alias Rfchat.Bots
  alias Rfchat.Chat
  alias Rfchat.Chat.Topics
  alias Rfchat.Chat.User
  alias Rfchat.Chat.Visibility
  alias RfchatWeb.API.ErrorHelpers

  @reauthorize_interval 20_000

  def index(conn, _params) do
    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      bots = Bots.list_controllable_bot_users(conn.assigns.current_user)
      json(conn, RfchatWeb.API.BotJSON.index(%{bots: bots}))
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def create(conn, %{"bot" => bot_params}) when is_map(bot_params) do
    actor = conn.assigns.current_user

    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      case Bots.create_bot(bot_params, actor) do
        {:ok, bot} ->
          conn
          |> put_status(:created)
          |> json(RfchatWeb.API.BotJSON.show(%{bot: bot}))

        {:error, :forbidden} ->
          forbidden(conn)

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

  def create(conn, _params), do: ErrorHelpers.render_invalid_body(conn)

  def update(conn, %{"id" => id, "bot" => bot_params}) when is_map(bot_params) do
    actor = conn.assigns.current_user

    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      case Bots.get_bot_user(id) do
        nil ->
          ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot not found.")

        bot ->
          case Bots.update_bot(bot, bot_params, actor) do
            {:ok, updated_bot} ->
              json(conn, RfchatWeb.API.BotJSON.show(%{bot: updated_bot}))

            {:error, :forbidden} ->
              forbidden(conn)

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

  def update(conn, _params), do: ErrorHelpers.render_invalid_body(conn)

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

            {:error, :forbidden} ->
              forbidden(conn)

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

  def create_token(conn, %{"id" => id, "token" => token_params}) when is_map(token_params) do
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

            {:error, :forbidden} ->
              forbidden(conn)

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

  def create_token(conn, _params), do: ErrorHelpers.render_invalid_body(conn)

  def list_tokens(conn, %{"id" => id}) do
    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      case Bots.list_controllable_bot_tokens(id, conn.assigns.current_user) do
        {:ok, tokens} ->
          json(conn, RfchatWeb.API.BotJSON.tokens(%{tokens: tokens}))

        {:error, :not_found} ->
          ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot not found.")
      end
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  def revoke_token(conn, %{"id" => id}) do
    actor = conn.assigns.current_user

    if Bots.can_manage_bots?(conn.assigns.current_scope) do
      token = Bots.get_bot_token(id)

      case token && Bots.revoke_bot_token(token, actor) do
        {:ok, revoked_token} ->
          json(conn, %{data: %{id: revoked_token.id, revoked_at: revoked_token.revoked_at}})

        {:error, :forbidden} ->
          forbidden(conn)

        _ ->
          ErrorHelpers.render_error(conn, :not_found, "not_found", "Bot token not found.")
      end
    else
      ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage bots.")
    end
  end

  # The membership can end between the auth plug and this call, so the member is read here too.
  def events(conn, _params) do
    case Bots.acting_member(conn.assigns.current_bot_scope) do
      {:ok, bot_user} -> open_events(conn, bot_user)
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  defp open_events(conn, bot_user) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    :ok = Topics.subscribe_guild()
    scope = conn.assigns.current_bot_scope
    subscribed = sync_subscriptions(MapSet.new(), scope)

    initial =
      "event: ready\ndata: #{Jason.encode!(%{bot: Bots.serialize_bot_user(bot_user)})}\n\n"

    case chunk(conn, initial) do
      {:ok, conn} ->
        schedule_reauthorize()

        stream_events(conn, %{
          token: bearer_token(conn),
          bot_user: bot_user,
          scope: scope,
          subscribed: subscribed
        })

      {:error, _reason} ->
        conn
    end
  end

  # Message events arrive only from the channel topics in `state.subscribed`: the channels and
  # threads the bot can view. A guild event re-syncs that set before anything is emitted, so a bot
  # that has received `thread.created` is already subscribed to that thread.
  #
  # A `:reauthorize` message, sent every `@reauthorize_interval`, re-checks the bearer token and
  # re-syncs subscriptions from the fresh bot user. It sits in the mailbox like any event, so the
  # check runs under steady traffic too. The loop ends when the token no longer authenticates the
  # same bot or when a write to the client fails.
  defp stream_events(conn, state) do
    receive do
      {:message_created, message} ->
        emit(conn, "message.created", Bots.serialize_message(message), state)

      {:message_updated, message} ->
        emit(conn, "message.updated", Bots.serialize_message(message), state)

      {:message_deleted, message} ->
        emit(conn, "message.deleted", Bots.serialize_message(message), state)

      {:channel_created, channel} ->
        state = resync(state)

        if channel.kind == :thread_public and MapSet.member?(state.subscribed, channel.id) do
          emit(conn, "thread.created", Bots.serialize_thread(channel), state)
        else
          stream_events(conn, state)
        end

      {event, _channel} when event in [:channel_updated, :channel_deleted] ->
        stream_events(conn, resync(state))

      :reauthorize ->
        reauthorize(conn, state)

      _other ->
        stream_events(conn, state)
    end
  end

  # A banned or removed bot keeps a valid token, so the member read is part of the check: a
  # bot with no active membership is closed like a revoked token.
  defp reauthorize(conn, state) do
    with {:ok, %Scope{user_id: id} = scope} when id == state.bot_user.id <-
           fetch_scope(state.token),
         %User{} = bot_user <- Visibility.member(scope) do
      state = resync(%{state | bot_user: bot_user})

      case chunk(conn, ": keepalive\n\n") do
        {:ok, conn} ->
          schedule_reauthorize()
          stream_events(conn, state)

        {:error, _reason} ->
          conn
      end
    else
      _revoked ->
        case chunk(conn, "event: closed\ndata: {\"reason\":\"token_revoked\"}\n\n") do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end
    end
  end

  defp emit(conn, event_name, payload, state) do
    case chunk(conn, "event: #{event_name}\ndata: #{Jason.encode!(payload)}\n\n") do
      {:ok, conn} -> stream_events(conn, state)
      {:error, _reason} -> conn
    end
  end

  defp schedule_reauthorize, do: Process.send_after(self(), :reauthorize, @reauthorize_interval)

  defp resync(state),
    do: %{state | subscribed: sync_subscriptions(state.subscribed, state.scope)}

  defp sync_subscriptions(subscribed, scope) do
    wanted =
      scope
      |> Chat.list_channels()
      |> Enum.reject(&(&1.kind == :category))
      |> MapSet.new(& &1.id)

    Topics.sync_channel_subscriptions(subscribed, wanted)
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp fetch_scope(nil), do: {:error, :unauthorized}
  defp fetch_scope(token), do: Bots.get_bot_scope_by_token(token)

  defp forbidden(conn),
    do: ErrorHelpers.render_error(conn, :forbidden, "forbidden", "You cannot manage this bot.")

  # The same answer RequireBotAuth gives a token it refuses, so a client sees one auth failure.
  defp unauthorized(conn),
    do:
      ErrorHelpers.render_error(
        conn,
        :unauthorized,
        "unauthorized",
        "Valid bot bearer token required."
      )
end
