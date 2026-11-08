defmodule Rfchat.Release do
  @moduledoc """
  Release tasks that run without Mix, such as the cartridge's migrate step (`bin/migrate`).
  """
  @app :rfchat

  @doc """
  Runs every pending migration, then provisions the seed data a fresh guild needs.
  """
  def migrate do
    Application.ensure_loaded(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
          Rfchat.Bootstrap.ensure_seed_data!()
        end)
    end
  end
end
