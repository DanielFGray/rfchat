defmodule Rfchat.Chat.MessageReport do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_reports" do
    field(:status, Ecto.Enum, values: [:open, :dismissed, :actioned], default: :open)
    field(:reason, :string)
    field(:notes, :string)
    field(:resolved_at, :utc_datetime_usec)

    belongs_to(:message, Rfchat.Chat.Message)
    belongs_to(:reporter_user, Rfchat.Chat.User)
    belongs_to(:resolver_user, Rfchat.Chat.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :message_id,
      :reporter_user_id,
      :resolver_user_id,
      :status,
      :reason,
      :notes,
      :resolved_at
    ])
    |> validate_required([:message_id, :reporter_user_id, :status])
  end
end
