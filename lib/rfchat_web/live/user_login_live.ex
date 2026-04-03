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
      <div class="min-h-screen bg-base-300 px-4 py-10 text-base-content sm:px-6 lg:px-8 transition-colors duration-200">
        <div class="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.15fr,0.85fr] lg:items-center">
          <section class="rounded-[2rem] border border-base-content/10 bg-base-100/90 p-8 shadow-xl lg:p-12">
            <p class="text-xs font-semibold uppercase tracking-[0.35em] text-primary">RFChat</p>
            <h1 class="mt-5 text-4xl font-semibold tracking-tight text-base-content lg:text-5xl">
              Log in to your guild.
            </h1>
            <p class="mt-5 max-w-xl text-base leading-7 text-base-content/70">
              Sign in with your own identity and chat as a real member of this self-hosted server.
            </p>
          </section>

          <section class="rounded-[2rem] border border-base-content/10 bg-base-100 p-6 shadow-xl lg:p-8">
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
                  <p class="text-2xl font-semibold text-base-content">Welcome back</p>
                  <p class="mt-2 text-sm text-base-content/70">
                    Use your email and password to enter the server.
                  </p>
                </div>

                <.input
                  field={@form[:email]}
                  type="email"
                  label="Email"
                  required
                  class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                />
                <.input
                  field={@form[:password]}
                  type="password"
                  label="Password"
                  required
                  class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                />
                <.input
                  field={@form[:remember_me]}
                  type="checkbox"
                  label="Remember me"
                  class="checkbox checkbox-sm rounded-md border-base-300 bg-base-200"
                />

                <button
                  id="login-submit"
                  type="submit"
                  class="inline-flex w-full items-center justify-center rounded-2xl bg-violet-500 px-4 py-3 text-sm font-semibold text-white transition hover:bg-violet-400"
                >
                  Log in
                </button>

                <p class="text-sm text-base-content/70">
                  Need an account?
                  <.link
                    navigate={~p"/register"}
                    class="font-semibold text-primary transition hover:text-primary/80"
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
