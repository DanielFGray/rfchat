defmodule Rfchat.Release do
  @moduledoc """
  Release tasks that run without Mix, such as the cartridge's migrate step (`bin/migrate`).
  """
  @app :rfchat

  @doc "Runs every pending migration, then provisions the seed data a fresh guild needs."
  def migrate do
    with_repo(fn repo ->
      Ecto.Migrator.run(repo, :up, all: true)
      Rfchat.Bootstrap.ensure_seed_data!()
    end)
  end

  @doc "Promote an existing account to the first server owner."
  def make_owner(email) do
    with_repo(fn _repo ->
      case Rfchat.Accounts.promote_first_owner(email) do
        {:ok, user} ->
          IO.puts("Made #{user.email} the server owner.")

        {:error, reason} ->
          IO.puts(:stderr, "Could not make #{email} the server owner: #{inspect(reason)}")
          System.halt(1)
      end
    end)
  end

  # Release Repo connections must bypass after_connect, which changes them to the visitor role.
  defp with_repo(fun) do
    Application.ensure_loaded(@app)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _} = repo.__adapter__().ensure_all_started(repo.config(), :temporary)
      {:ok, pid} = repo.start_link(pool_size: 2, after_connect: nil)

      try do
        fun.(repo)
      after
        Supervisor.stop(pid)
      end
    end
  end
end
