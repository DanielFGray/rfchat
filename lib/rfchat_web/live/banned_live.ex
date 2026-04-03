defmodule RfchatWeb.BannedLive do
  use RfchatWeb, :live_view

  alias Rfchat.Accounts
  alias Rfchat.Chat

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    membership = user.membership
    flags = membership.flags || %{}

    server_settings = Chat.get_server_settings()

    {:ok,
     socket
     |> assign(:page_title, "Banned")
     |> assign(:server_settings, server_settings)
     |> assign(:current_server, server_settings)
     |> assign(:ban_reason, Map.get(flags, "ban_reason"))
     |> assign(:ban_at, membership.deactivated_at)
     |> assign(:timed_out?, Accounts.timed_out?(user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-base-300 px-4 py-10 text-base-content sm:px-6 lg:px-8 transition-colors duration-200">
        <div class="mx-auto max-w-3xl rounded-[2rem] border border-error/20 bg-base-100 p-8 shadow-xl lg:p-10">
          <Layouts.server_identity server={@server_settings} class="mb-6" />
          <h1 class="mt-5 text-4xl font-semibold tracking-tight text-base-content lg:text-5xl">
            This account is banned from this server.
          </h1>
          <p class="mt-5 max-w-2xl text-base leading-7 text-base-content/70">
            Because each RFChat deployment is a single server, this ban blocks access to the server shell while still letting us explain what happened.
          </p>

          <div class="mt-8 grid gap-4 rounded-2xl border border-base-300 bg-base-200 p-5 sm:grid-cols-2">
            <div>
              <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-base-content/50">
                Account
              </p>
              <p class="mt-2 text-sm font-medium text-base-content">@{@current_user.username}</p>
              <p class="mt-1 text-sm text-base-content/70">{@current_user.display_name}</p>
            </div>

            <div>
              <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-base-content/50">
                Banned at
              </p>
              <p class="mt-2 text-sm text-base-content">
                {if @ban_at,
                  do: Calendar.strftime(@ban_at, "%b %-d, %Y at %H:%M UTC"),
                  else: "Unavailable"}
              </p>
            </div>
          </div>

          <div class="mt-6 rounded-2xl border border-base-300 bg-base-200 p-5">
            <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-base-content/50">
              Reason
            </p>
            <p class="mt-3 text-sm leading-7 text-base-content/85">
              {if is_binary(@ban_reason) and String.trim(@ban_reason) != "",
                do: @ban_reason,
                else: "No public reason was provided."}
            </p>
          </div>

          <div class="mt-6 flex flex-wrap items-center gap-3">
            <.link
              navigate={~p"/logout"}
              method="delete"
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
