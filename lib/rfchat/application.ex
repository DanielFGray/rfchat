defmodule Rfchat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RfchatWeb.Telemetry,
      Rfchat.Repo,
      Rfchat.Accounts.LoginRateLimiter,
      {DNSCluster, query: Application.get_env(:rfchat, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Rfchat.PubSub},
      # Start a worker by calling: Rfchat.Worker.start_link(arg)
      # {Rfchat.Worker, arg},
      # Start to serve requests, typically the last entry
      RfchatWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rfchat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RfchatWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
