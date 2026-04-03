defmodule Rfchat.Repo.Migrations.AllowMultipleOwners do
  use Ecto.Migration

  def change do
    # Drop the unique partial index that enforced a single owner.
    drop_if_exists(unique_index(:memberships, [:is_owner], where: "is_owner = true"))

    # Replace with a non-unique partial index for query performance
    # (e.g. "give me all owners" lookups).
    create(index(:memberships, [:is_owner], where: "is_owner = true"))
  end
end
