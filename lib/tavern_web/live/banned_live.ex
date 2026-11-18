defmodule TavernWeb.BannedLive do
  use TavernWeb, :live_view

  alias Tavern.Accounts
  alias Tavern.Chat

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    state = Accounts.membership_state(user)

    server_settings = Chat.get_server_settings()

    socket =
      socket
      |> assign(:state, state)
      |> assign(:page_title, if(state == :banned, do: "Banned", else: "Removed"))
      |> assign(:server_settings, server_settings)
      |> assign(:current_server, server_settings)

    {:ok, assign_ban_details(socket, state, user.membership)}
  end

  # Only a ban carries a reason and a time to show. A kick keeps its membership
  # row but has no ban flags, so its page shows neither.
  defp assign_ban_details(socket, :banned, membership) do
    flags = membership.flags || %{}

    socket
    |> assign(:ban_reason, Map.get(flags, "ban_reason"))
    |> assign(:ban_at, membership.deactivated_at)
  end

  defp assign_ban_details(socket, _state, _membership), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-base-300 px-4 py-10 text-base-content sm:px-6 lg:px-8 transition-colors duration-200">
        <div
          id={"#{@state}-page"}
          class="mx-auto max-w-3xl rounded-[2rem] border border-error/20 bg-base-100 p-8 shadow-xl lg:p-10"
        >
          <Layouts.server_identity server={@server_settings} class="mb-6" />

          <%= if @state == :banned do %>
            <h1
              id="banned-heading"
              class="mt-5 text-4xl font-semibold tracking-tight text-base-content lg:text-5xl"
            >
              This account is banned from this server.
            </h1>
            <p class="mt-5 max-w-2xl text-base leading-7 text-base-content/70">
              Because each Tavern deployment is a single server, this ban blocks access to the server shell while still letting us explain what happened.
            </p>
          <% else %>
            <h1
              id="removed-heading"
              class="mt-5 text-4xl font-semibold tracking-tight text-base-content lg:text-5xl"
            >
              This account was removed from this server.
            </h1>
            <p class="mt-5 max-w-2xl text-base leading-7 text-base-content/70">
              A moderator removed this account from the server, so its channels are closed to it.
            </p>
          <% end %>

          <div class="mt-8 grid gap-4 rounded-2xl border border-base-300 bg-base-200 p-5 sm:grid-cols-2">
            <div>
              <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-base-content/50">
                Account
              </p>
              <p class="mt-2 text-sm font-medium text-base-content">@{@current_user.username}</p>
              <p class="mt-1 text-sm text-base-content/70">{@current_user.display_name}</p>
            </div>

            <%= if @state == :banned do %>
              <div id="banned-at">
                <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-base-content/50">
                  Banned at
                </p>
                <p class="mt-2 text-sm text-base-content">
                  {if @ban_at,
                    do: Calendar.strftime(@ban_at, "%b %-d, %Y at %H:%M UTC"),
                    else: "Unavailable"}
                </p>
              </div>
            <% end %>
          </div>

          <%= if @state == :banned do %>
            <div id="ban-reason" class="mt-6 rounded-2xl border border-base-300 bg-base-200 p-5">
              <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-base-content/50">
                Reason
              </p>
              <p class="mt-3 text-sm leading-7 text-base-content/85">
                {if is_binary(@ban_reason) and String.trim(@ban_reason) != "",
                  do: @ban_reason,
                  else: "No public reason was provided."}
              </p>
            </div>
          <% end %>

          <div class="mt-6 flex flex-wrap items-center gap-3">
            <.link
              href={~p"/logout"}
              method="delete"
              id="logout-link"
              class="inline-flex items-center justify-center rounded-2xl bg-rose-500 px-4 py-3 text-sm font-semibold text-white transition hover:bg-rose-400"
            >
              Log out
            </.link>
            <p class="text-sm text-base-content/60">
              If you believe this is a mistake, contact the server operator directly.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
