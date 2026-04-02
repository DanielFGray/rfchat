defmodule Rfchat.Repo.Migrations.AddDiscordLikeStructure do
  use Ecto.Migration

  def change do
    create table(:media_assets, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:uploader_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:kind, :string, null: false)
      add(:storage_provider, :string, null: false, default: "local")
      add(:storage_key, :string, null: false)
      add(:original_filename, :string)
      add(:content_type, :string)
      add(:byte_size, :bigint, null: false)
      add(:sha256, :string)
      add(:width, :integer)
      add(:height, :integer)
      add(:duration_ms, :integer)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:media_assets, [:uploader_id]))
    create(unique_index(:media_assets, [:storage_provider, :storage_key]))

    alter table(:users) do
      add(:bio, :text)
      add(:avatar_asset_id, references(:media_assets, type: :binary_id, on_delete: :nilify_all))
      add(:banner_asset_id, references(:media_assets, type: :binary_id, on_delete: :nilify_all))
      add(:bot, :boolean, null: false, default: false)
      add(:system, :boolean, null: false, default: false)
      add(:deleted_at, :utc_datetime_usec)
    end

    create(index(:users, [:avatar_asset_id]))
    create(index(:users, [:banner_asset_id]))

    create table(:memberships, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:nickname, :string)
      add(:pronouns, :string)

      add(
        :server_avatar_asset_id,
        references(:media_assets, type: :binary_id, on_delete: :nilify_all)
      )

      add(:joined_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec)
      add(:timeout_until, :utc_datetime_usec)
      add(:deactivated_at, :utc_datetime_usec)
      add(:is_owner, :boolean, null: false, default: false)
      add(:flags, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:memberships, [:user_id]))
    create(index(:memberships, [:server_avatar_asset_id]))
    create(unique_index(:memberships, [:is_owner], where: "is_owner = true"))

    create table(:roles, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:color, :integer, null: false, default: 0)
      add(:permissions, :bigint, null: false, default: 0)
      add(:position, :integer, null: false, default: 0)
      add(:mentionable, :boolean, null: false, default: false)
      add(:hoist, :boolean, null: false, default: false)
      add(:managed, :boolean, null: false, default: false)
      add(:is_default, :boolean, null: false, default: false)
      add(:icon_asset_id, references(:media_assets, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:roles, [:position]))
    create(index(:roles, [:icon_asset_id]))
    create(unique_index(:roles, [:is_default], where: "is_default = true"))

    create table(:member_roles, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false)
      add(:granted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:member_roles, [:user_id, :role_id]))
    create(index(:member_roles, [:role_id]))
    create(index(:member_roles, [:granted_by_user_id]))

    drop_if_exists(index(:channels, [:position]))

    alter table(:channels) do
      add(:kind, :string, null: false, default: "text")
      add(:parent_channel_id, references(:channels, type: :binary_id, on_delete: :delete_all))
      add(:created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:starter_message_id, references(:messages, type: :binary_id, on_delete: :nilify_all))
      add(:nsfw, :boolean, null: false, default: false)
      add(:slowmode_seconds, :integer, null: false, default: 0)
      add(:default_auto_archive_minutes, :integer, null: false, default: 1440)
      add(:archived_at, :utc_datetime_usec)
      add(:locked_at, :utc_datetime_usec)
    end

    create(index(:channels, [:kind]))
    create(index(:channels, [:parent_channel_id, :position]))
    create(index(:channels, [:created_by_id]))
    create(index(:channels, [:starter_message_id]))

    create table(:channel_memberships, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:last_read_message_id, references(:messages, type: :binary_id, on_delete: :nilify_all))
      add(:last_read_at, :utc_datetime_usec)
      add(:notification_level, :string, null: false, default: "default")
      add(:muted_until, :utc_datetime_usec)
      add(:is_favorite, :boolean, null: false, default: false)
      add(:joined_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:channel_memberships, [:channel_id, :user_id]))
    create(index(:channel_memberships, [:user_id, :notification_level]))
    create(index(:channel_memberships, [:last_read_message_id]))

    create table(:channel_permission_overwrites, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:role_id, references(:roles, type: :binary_id, on_delete: :delete_all))
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))
      add(:allow_permissions, :bigint, null: false, default: 0)
      add(:deny_permissions, :bigint, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:channel_permission_overwrites, [:channel_id]))

    create(
      unique_index(:channel_permission_overwrites, [:channel_id, :role_id],
        where: "role_id IS NOT NULL"
      )
    )

    create(
      unique_index(:channel_permission_overwrites, [:channel_id, :user_id],
        where: "user_id IS NOT NULL"
      )
    )

    create(
      constraint(:channel_permission_overwrites, :single_overwrite_target,
        check:
          "(role_id IS NOT NULL AND user_id IS NULL) OR (role_id IS NULL AND user_id IS NOT NULL)"
      )
    )

    alter table(:messages) do
      add(:kind, :string, null: false, default: "default")
      add(:reply_to_id, references(:messages, type: :binary_id, on_delete: :nilify_all))
      add(:edited_at, :utc_datetime_usec)
      add(:deleted_at, :utc_datetime_usec)
      add(:pinned_at, :utc_datetime_usec)
      add(:nonce, :string)
      add(:metadata, :map, null: false, default: %{})
    end

    create(index(:messages, [:reply_to_id]))
    create(index(:messages, [:channel_id, :pinned_at]))
    create(index(:messages, [:channel_id, :deleted_at]))
    create(unique_index(:messages, [:channel_id, :nonce], where: "nonce IS NOT NULL"))

    create table(:emojis, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:shortcode, :string, null: false)

      add(:asset_id, references(:media_assets, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:creator_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:requires_colons, :boolean, null: false, default: true)
      add(:managed, :boolean, null: false, default: false)
      add(:available, :boolean, null: false, default: true)
      add(:listed, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:emojis, [:name]))
    create(unique_index(:emojis, [:shortcode]))
    create(index(:emojis, [:asset_id]))
    create(index(:emojis, [:creator_id]))

    create table(:channel_tags, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:emoji_id, references(:emojis, type: :binary_id, on_delete: :nilify_all))
      add(:emoji_unicode, :string)
      add(:moderated, :boolean, null: false, default: false)
      add(:position, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:channel_tags, [:channel_id, :name]))
    create(index(:channel_tags, [:channel_id, :position]))

    create(
      constraint(:channel_tags, :tag_emoji_target,
        check: "NOT (emoji_id IS NOT NULL AND emoji_unicode IS NOT NULL)"
      )
    )

    create table(:channel_tag_assignments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:thread_channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:tag_id, references(:channel_tags, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:channel_tag_assignments, [:thread_channel_id, :tag_id]))

    create table(:emoji_roles, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:emoji_id, references(:emojis, type: :binary_id, on_delete: :delete_all), null: false)
      add(:role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:emoji_roles, [:emoji_id, :role_id]))

    create table(:stickers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:tags, {:array, :string}, null: false, default: [])
      add(:format, :string, null: false, default: "png")

      add(:asset_id, references(:media_assets, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:creator_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:available, :boolean, null: false, default: true)
      add(:sort_value, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:stickers, [:name]))
    create(index(:stickers, [:asset_id]))
    create(index(:stickers, [:sort_value]))

    create table(:message_attachments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:asset_id, references(:media_assets, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string, null: false, default: "file")
      add(:position, :integer, null: false, default: 0)
      add(:description, :text)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:message_attachments, [:message_id, :position]))
    create(index(:message_attachments, [:asset_id]))

    create table(:reactions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:emoji_id, references(:emojis, type: :binary_id, on_delete: :delete_all))
      add(:emoji_unicode, :string)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:reactions, [:message_id]))

    create(
      unique_index(:reactions, [:message_id, :user_id, :emoji_id], where: "emoji_id IS NOT NULL")
    )

    create(
      unique_index(:reactions, [:message_id, :user_id, :emoji_unicode],
        where: "emoji_unicode IS NOT NULL"
      )
    )

    create(
      constraint(:reactions, :single_reaction_emoji,
        check:
          "(emoji_id IS NOT NULL AND emoji_unicode IS NULL) OR (emoji_id IS NULL AND emoji_unicode IS NOT NULL)"
      )
    )

    create table(:message_user_mentions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:mentioned_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:message_user_mentions, [:message_id, :mentioned_user_id]))

    create table(:message_role_mentions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:mentioned_role_id, references(:roles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:message_role_mentions, [:message_id, :mentioned_role_id]))

    create table(:invites, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:code, :string, null: false)

      add(:channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:inviter_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:max_uses, :integer)
      add(:uses, :integer, null: false, default: 0)
      add(:expires_at, :utc_datetime_usec)
      add(:temporary, :boolean, null: false, default: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:last_used_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:invites, [:code]))
    create(index(:invites, [:channel_id]))
    create(index(:invites, [:expires_at]))

    create table(:invite_uses, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:invite_id, references(:invites, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:used_at, :utc_datetime_usec, null: false)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:invite_uses, [:invite_id]))
    create(index(:invite_uses, [:user_id]))

    create table(:moderation_cases, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:case_number, :bigint, null: false)
      add(:action_type, :string, null: false)
      add(:state, :string, null: false, default: "open")

      add(:actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all),
        null: false
      )

      add(:subject_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:channel_id, references(:channels, type: :binary_id, on_delete: :nilify_all))
      add(:message_id, references(:messages, type: :binary_id, on_delete: :nilify_all))
      add(:reason, :text)
      add(:details, :map, null: false, default: %{})
      add(:expires_at, :utc_datetime_usec)
      add(:executed_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:revoked_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:moderation_cases, [:case_number]))
    create(index(:moderation_cases, [:subject_user_id, :inserted_at]))
    create(index(:moderation_cases, [:actor_user_id, :inserted_at]))
    create(index(:moderation_cases, [:state, :action_type]))

    create table(:message_reports, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:reporter_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:resolver_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:status, :string, null: false, default: "open")
      add(:reason, :text)
      add(:notes, :text)
      add(:resolved_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:message_reports, [:message_id]))
    create(index(:message_reports, [:status, :inserted_at]))

    create table(:audit_log_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:action_type, :string, null: false)
      add(:actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:subject_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:channel_id, references(:channels, type: :binary_id, on_delete: :nilify_all))
      add(:message_id, references(:messages, type: :binary_id, on_delete: :nilify_all))
      add(:target_type, :string)
      add(:target_id, :string)
      add(:reason, :text)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:audit_log_entries, [:action_type, :inserted_at]))
    create(index(:audit_log_entries, [:actor_user_id, :inserted_at]))
    create(index(:audit_log_entries, [:subject_user_id, :inserted_at]))

    create table(:user_notification_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:desktop_enabled, :boolean, null: false, default: true)
      add(:email_enabled, :boolean, null: false, default: false)
      add(:push_enabled, :boolean, null: false, default: false)
      add(:notify_on_all_messages, :boolean, null: false, default: false)
      add(:notify_on_mentions, :boolean, null: false, default: true)
      add(:suppress_everyone, :boolean, null: false, default: false)
      add(:suppress_roles, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:user_notification_settings, [:user_id]))

    create table(:channel_notification_overrides, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(:channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:level, :string, null: false, default: "default")
      add(:muted_until, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:channel_notification_overrides, [:user_id, :channel_id]))

    create table(:user_sessions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      add(:user_agent, :text)
      add(:ip_address, :string)
      add(:last_seen_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:user_sessions, [:token_hash]))
    create(index(:user_sessions, [:user_id, :expires_at]))
  end
end
