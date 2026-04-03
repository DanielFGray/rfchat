defmodule RfchatWeb.UserRegistrationLive do
  use RfchatWeb, :live_view

  alias Ecto.Changeset
  alias Rfchat.Accounts
  alias Rfchat.Chat
  alias Rfchat.Chat.User

  @impl true
  def mount(_params, _session, socket) do
    form = %User{} |> Accounts.change_registration_user() |> to_form()

    server_settings = Chat.get_server_settings()

    {:ok,
     socket
     |> assign(:page_title, "Register")
     |> assign(:server_settings, server_settings)
     |> assign(:current_server, server_settings)
     |> assign(:form, form)}
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      %User{}
      |> Accounts.change_registration_user(user_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        message =
          if user.membership && user.membership.is_owner do
            "Account created. You are a server owner. Log in to continue."
          else
            "Account created. Log in to continue."
          end

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: ~p"/login")}

      {:error, %Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-base-300 px-4 py-10 text-base-content sm:px-6 lg:px-8 transition-colors duration-200">
        <div class="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.05fr,0.95fr] lg:items-center">
          <section class="rounded-[2rem] border border-base-content/10 bg-base-100/90 p-8 shadow-xl lg:p-12">
            <Layouts.server_identity server={@server_settings} class="mb-6" />
            <h1 class="mt-5 text-4xl font-semibold tracking-tight text-base-content lg:text-5xl">
              Create your {@server_settings.name} identity.
            </h1>
            <p class="mt-5 max-w-xl text-base leading-7 text-base-content/70">
              Register once for this self-hosted guild instance, then chat under your own profile.
            </p>
          </section>

          <section class="rounded-[2rem] border border-base-content/10 bg-base-100 p-6 shadow-xl lg:p-8">
            <.form for={@form} id="registration-form" phx-change="validate" phx-submit="save">
              <div class="space-y-5">
                <div>
                  <p class="text-2xl font-semibold text-base-content">Create account</p>
                  <p class="mt-2 text-sm text-base-content/70">
                    Your user becomes a member of this single guild instance.
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
                  field={@form[:username]}
                  type="text"
                  label="Username"
                  required
                  class="w-full rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-base-content"
                />
                <.input
                  field={@form[:display_name]}
                  type="text"
                  label="Display name"
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

                <button
                  id="registration-submit"
                  type="submit"
                  class="inline-flex w-full items-center justify-center rounded-2xl bg-emerald-500 px-4 py-3 text-sm font-semibold text-zinc-950 transition hover:bg-emerald-400"
                >
                  Create account
                </button>

                <p class="text-sm text-base-content/70">
                  Already have an account?
                  <.link
                    navigate={~p"/login"}
                    class="font-semibold text-primary transition hover:text-primary/80"
                  >
                    Log in
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
