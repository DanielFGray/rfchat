defmodule Rfchat.Repo do
  use Ecto.Repo,
    otp_app: :rfchat,
    adapter: Ecto.Adapters.Postgres
end
