defmodule Rfchat.Chat.AuditLogEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_log_entries" do
    field(:action_type, :string)
    field(:target_type, :string)
    field(:target_id, :string)
    field(:reason, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:actor_user, Rfchat.Chat.User)
    belongs_to(:subject_user, Rfchat.Chat.User)
    belongs_to(:channel, Rfchat.Chat.Channel)
    belongs_to(:message, Rfchat.Chat.Message)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :action_type,
      :actor_user_id,
      :subject_user_id,
      :channel_id,
      :message_id,
      :target_type,
      :target_id,
      :reason,
      :metadata
    ])
    |> validate_required([:action_type])
  end
end
