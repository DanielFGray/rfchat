defmodule RfchatWeb.Router do
  use RfchatWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {RfchatWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(RfchatWeb.UserAuth, :fetch_current_scope_for_user)
  end

  pipeline :require_authenticated_user do
    plug(RfchatWeb.UserAuth, :require_authenticated_user)
  end

  pipeline :require_banned_user do
    plug(RfchatWeb.UserAuth, :require_banned_user)
  end

  pipeline :redirect_if_user_is_authenticated do
    plug(RfchatWeb.UserAuth, :redirect_if_user_is_authenticated)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", RfchatWeb do
    pipe_through(:browser)

    delete("/logout", UserSessionController, :delete)
  end

  scope "/", RfchatWeb do
    pipe_through([:browser, :redirect_if_user_is_authenticated])

    post("/login", UserSessionController, :create)

    live_session :redirect_if_user_is_authenticated,
      on_mount: [{RfchatWeb.UserAuth, :redirect_if_user_is_authenticated}] do
      live("/register", UserRegistrationLive, :new)
      live("/login", UserLoginLive, :new)
    end
  end

  scope "/", RfchatWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :require_authenticated_user,
      on_mount: [{RfchatWeb.UserAuth, :ensure_authenticated}] do
      live("/", GuildLive, :index)
    end
  end

  scope "/", RfchatWeb do
    pipe_through([:browser, :require_banned_user])

    live_session :require_banned_user,
      on_mount: [{RfchatWeb.UserAuth, :ensure_banned_user}] do
      live("/banned", BannedLive, :index)
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", RfchatWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:rfchat, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: RfchatWeb.Telemetry)
    end
  end
end
