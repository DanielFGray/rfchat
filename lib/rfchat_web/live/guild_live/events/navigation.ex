defmodule RfchatWeb.GuildLive.Events.Navigation do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Rfchat.Chat
  alias RfchatWeb.GuildLive.State

  def handle_params(%{"thread" => thread_id} = params, _uri, socket) do
    socket =
      case params do
        %{"channel" => slug} ->
          case Chat.get_channel_by_slug_for_user(slug, socket.assigns.current_user) do
            {:ok, channel} ->
              socket
              |> assign(:active_thread, nil)
              |> assign(:thread_focus?, false)
              |> State.load_channel(channel)

            _ ->
              socket
          end

        _ ->
          socket
      end

    case Chat.get_thread_for_user(thread_id, socket.assigns.current_user) do
      {:ok, thread} ->
        {:noreply, State.open_thread(socket, thread, focus?: true)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That thread does not exist.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have access to that thread.")}
    end
  end

  def handle_params(%{"channel" => slug}, _uri, socket) do
    case Chat.get_channel_by_slug_for_user(slug, socket.assigns.current_user) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:active_thread, nil)
         |> assign(:thread_focus?, false)
         |> State.load_channel(channel)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "That channel does not exist.")
         |> State.redirect_to_default_channel()}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have access to that channel.")
         |> State.redirect_to_default_channel()}
    end
  end

  def handle_params(_params, _uri, socket) do
    case {socket.assigns.active_channel, List.first(socket.assigns.channels)} do
      {nil, %{} = channel} -> {:noreply, State.load_channel(socket, channel)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:channel_created, channel}, socket) do
    {:noreply, State.maybe_refresh_thread_summaries(socket, channel)}
  end

  def handle_info({:channel_updated, _channel}, socket) do
    {:noreply, State.refresh_channels(socket)}
  end

  def handle_info({:channel_deleted, channel}, socket) do
    socket = State.refresh_channels(socket)

    cond do
      socket.assigns.active_channel && socket.assigns.active_channel.id == channel.id ->
        {:noreply,
         socket
         |> put_flash(:info, "Channel deleted.")
         |> State.redirect_to_default_channel()}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(:channels_reordered, socket) do
    {:noreply, State.refresh_channels(socket)}
  end
end
