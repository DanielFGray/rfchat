defmodule Rfchat.Chat.MemberRole do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "member_roles" do
    belongs_to(:user, Rfchat.Chat.User)
    belongs_to(:role, Rfchat.Chat.Role)
    belongs_to(:granted_by_user, Rfchat.Chat.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(member_role, attrs) do
    member_role
    |> cast(attrs, [:user_id, :role_id, :granted_by_user_id])
    |> validate_required([:user_id, :role_id])
    |> unique_constraint([:user_id, :role_id])
  end
end
