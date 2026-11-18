defmodule Tavern.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TavernWeb.Telemetry,
      Tavern.Repo,
      Tavern.Redis,
      Tavern.Accounts.LoginRateLimiter,
      {DNSCluster, query: Application.get_env(:tavern, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tavern.PubSub},
      # Start a worker by calling: Tavern.Worker.start_link(arg)
      # {Tavern.Worker, arg},
      # Start to serve requests, typically the last entry
      TavernWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tavern.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TavernWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
