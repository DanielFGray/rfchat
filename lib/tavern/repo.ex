defmodule Tavern.Repo do
  use Ecto.Repo,
    otp_app: :tavern,
    adapter: Ecto.Adapters.Postgres
end
