defmodule RfchatWeb.UserLoginLive do
  use RfchatWeb, :live_view

  alias Rfchat.Accounts

  @impl true
  def mount(_params, _session, socket) do
    form = Accounts.dummy_login_changeset() |> to_form(as: :user)

    {:ok,
     socket
     |> assign(:page_title, "Log in")
     |> assign(:form, form)
     |> assign(:trigger_submit, false)}
  end

  @impl true
  def handle_event("submit", %{"user" => user_params}, socket) do
    {:noreply,
     socket
     |> assign(:trigger_submit, true)
     |> assign(:form, to_form(user_params, as: :user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-zinc-950 px-4 py-10 text-zinc-100 sm:px-6 lg:px-8">
        <div class="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.15fr,0.85fr] lg:items-center">
          <section class="rounded-[2rem] border border-zinc-800 bg-zinc-900/60 p-8 shadow-[0_0_0_1px_rgba(255,255,255,0.03)] lg:p-12">
            <p class="text-xs font-semibold uppercase tracking-[0.35em] text-violet-300">RFChat</p>
            <h1 class="mt-5 text-4xl font-semibold tracking-tight text-white lg:text-5xl">
              Log in to your guild.
            </h1>
            <p class="mt-5 max-w-xl text-base leading-7 text-zinc-400">
              Sign in with your own identity and chat as a real member of this self-hosted server.
            </p>
          </section>

          <section class="rounded-[2rem] border border-zinc-800 bg-zinc-900/80 p-6 shadow-[0_0_0_1px_rgba(255,255,255,0.03)] lg:p-8">
            <.form
              for={@form}
              id="login-form"
              action={~p"/login"}
              method="post"
              phx-submit="submit"
              phx-trigger-action={@trigger_submit}
            >
              <div class="space-y-5">
                <div>
                  <p class="text-2xl font-semibold text-white">Welcome back</p>
                  <p class="mt-2 text-sm text-zinc-400">
                    Use your email and password to enter the server.
                  </p>
                </div>

                <.input
                  field={@form[:email]}
                  type="email"
                  label="Email"
                  required
                  class="w-full rounded-2xl border border-zinc-800 bg-zinc-950 px-4 py-3 text-zinc-100"
                />
                <.input
                  field={@form[:password]}
                  type="password"
                  label="Password"
                  required
                  class="w-full rounded-2xl border border-zinc-800 bg-zinc-950 px-4 py-3 text-zinc-100"
                />
                <.input
                  field={@form[:remember_me]}
                  type="checkbox"
                  label="Remember me"
                  class="checkbox checkbox-sm rounded-md border-zinc-700 bg-zinc-950"
                />

                <button
                  id="login-submit"
                  type="submit"
                  class="inline-flex w-full items-center justify-center rounded-2xl bg-violet-500 px-4 py-3 text-sm font-semibold text-white transition hover:bg-violet-400"
                >
                  Log in
                </button>

                <p class="text-sm text-zinc-400">
                  Need an account?
                  <.link
                    navigate={~p"/register"}
                    class="font-semibold text-violet-300 hover:text-violet-200"
                  >
                    Create one
                  </.link>
                </p>
              </div>
            </.form>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
