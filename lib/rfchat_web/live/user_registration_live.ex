defmodule RfchatWeb.UserRegistrationLive do
  use RfchatWeb, :live_view

  alias Ecto.Changeset
  alias Rfchat.Accounts
  alias Rfchat.Chat.User

  @impl true
  def mount(_params, _session, socket) do
    form = %User{} |> Accounts.change_registration_user() |> to_form()

    {:ok,
     socket
     |> assign(:page_title, "Register")
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
            "Account created. You are this server's owner. Log in to continue."
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
      <div class="min-h-screen bg-zinc-950 px-4 py-10 text-zinc-100 sm:px-6 lg:px-8">
        <div class="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.05fr,0.95fr] lg:items-center">
          <section class="rounded-[2rem] border border-zinc-800 bg-zinc-900/60 p-8 shadow-[0_0_0_1px_rgba(255,255,255,0.03)] lg:p-12">
            <p class="text-xs font-semibold uppercase tracking-[0.35em] text-emerald-300">Account</p>
            <h1 class="mt-5 text-4xl font-semibold tracking-tight text-white lg:text-5xl">
              Create your RFChat identity.
            </h1>
            <p class="mt-5 max-w-xl text-base leading-7 text-zinc-400">
              Register once for this self-hosted guild instance, then chat under your own profile.
            </p>
          </section>

          <section class="rounded-[2rem] border border-zinc-800 bg-zinc-900/80 p-6 shadow-[0_0_0_1px_rgba(255,255,255,0.03)] lg:p-8">
            <.form for={@form} id="registration-form" phx-change="validate" phx-submit="save">
              <div class="space-y-5">
                <div>
                  <p class="text-2xl font-semibold text-white">Create account</p>
                  <p class="mt-2 text-sm text-zinc-400">
                    Your user becomes a member of this single guild instance.
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
                  field={@form[:username]}
                  type="text"
                  label="Username"
                  required
                  class="w-full rounded-2xl border border-zinc-800 bg-zinc-950 px-4 py-3 text-zinc-100"
                />
                <.input
                  field={@form[:display_name]}
                  type="text"
                  label="Display name"
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

                <button
                  id="registration-submit"
                  type="submit"
                  class="inline-flex w-full items-center justify-center rounded-2xl bg-emerald-500 px-4 py-3 text-sm font-semibold text-zinc-950 transition hover:bg-emerald-400"
                >
                  Create account
                </button>

                <p class="text-sm text-zinc-400">
                  Already have an account?
                  <.link
                    navigate={~p"/login"}
                    class="font-semibold text-violet-300 hover:text-violet-200"
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
