defmodule Rfchat.Release do
  @moduledoc """
  Release tasks that run without Mix, such as the cartridge's migrate step (`bin/migrate`).
  """
  @app :rfchat

  @doc """
  Runs every pending migration, then provisions the seed data a fresh guild needs.

  The Repo starts here without the runtime config's `after_connect`, which switches server
  connections to the visitor role: migrations run as the migration login, which owns the
  schema and cannot take that role. `Ecto.Migrator.with_repo/3` passes only `:pool_size` to
  the Repo, so it cannot drop the callback.
  """
  def migrate do
    Application.ensure_loaded(@app)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _} = repo.__adapter__().ensure_all_started(repo.config(), :temporary)
      {:ok, pid} = repo.start_link(pool_size: 2, after_connect: nil)

      try do
        Ecto.Migrator.run(repo, :up, all: true)
        Rfchat.Bootstrap.ensure_seed_data!()
      after
        Supervisor.stop(pid)
      end
    end
  end
end
