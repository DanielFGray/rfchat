defmodule Rfchat.Chat.UserNotificationSetting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_notification_settings" do
    field(:desktop_enabled, :boolean, default: true)
    field(:email_enabled, :boolean, default: false)
    field(:push_enabled, :boolean, default: false)
    field(:notify_on_all_messages, :boolean, default: false)
    field(:notify_on_mentions, :boolean, default: true)
    field(:suppress_everyone, :boolean, default: false)
    field(:suppress_roles, :boolean, default: false)

    belongs_to(:user, Rfchat.Chat.User)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :user_id,
      :desktop_enabled,
      :email_enabled,
      :push_enabled,
      :notify_on_all_messages,
      :notify_on_mentions,
      :suppress_everyone,
      :suppress_roles
    ])
    |> validate_required([:user_id])
    |> unique_constraint(:user_id)
  end
end
