defmodule RfchatWeb.GuildLive.Events.Mobile do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias RfchatWeb.GuildLive.State

  def handle_event("toggle_mobile_sidebar", _params, socket) do
    next_open? = !socket.assigns.mobile_sidebar_open?

    {:noreply,
     socket
     |> State.close_message_ui()
     |> assign(:mobile_members_open?, false)
     |> assign(:mobile_sidebar_open?, next_open?)}
  end

  def handle_event("close_mobile_sidebar", _params, socket) do
    {:noreply, assign(socket, :mobile_sidebar_open?, false)}
  end

  def handle_event("toggle_mobile_members", _params, socket) do
    next_open? = !socket.assigns.mobile_members_open?

    {:noreply,
     socket
     |> State.close_message_ui()
     |> assign(:mobile_sidebar_open?, false)
     |> assign(:mobile_members_open?, next_open?)}
  end

  def handle_event("close_mobile_members", _params, socket) do
    {:noreply, assign(socket, :mobile_members_open?, false)}
  end
end
