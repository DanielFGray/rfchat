defmodule Tavern.Chat.ModerationCase do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "moderation_cases" do
    field(:case_number, :integer)

    field(:action_type, Ecto.Enum,
      values: [:warn, :kick, :ban, :timeout, :unban, :delete_message, :edit_role, :other]
    )

    field(:state, Ecto.Enum, values: [:open, :executed, :revoked, :expired], default: :open)
    field(:reason, :string)
    field(:details, :map, default: %{})
    field(:expires_at, :utc_datetime_usec)
    field(:executed_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:actor_user, Tavern.Chat.User)
    belongs_to(:subject_user, Tavern.Chat.User)
    belongs_to(:channel, Tavern.Chat.Channel)
    belongs_to(:message, Tavern.Chat.Message)
    belongs_to(:revoked_by_user, Tavern.Chat.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(moderation_case, attrs) do
    moderation_case
    |> cast(attrs, [
      :case_number,
      :action_type,
      :state,
      :actor_user_id,
      :subject_user_id,
      :channel_id,
      :message_id,
      :reason,
      :details,
      :expires_at,
      :executed_at,
      :revoked_at,
      :revoked_by_user_id
    ])
    |> validate_required([:action_type, :state, :actor_user_id])
    |> unique_constraint(:case_number)
  end
end
