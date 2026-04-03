defmodule Rfchat.Bots.Serializer do
  @moduledoc false

  alias Rfchat.Chat.User

  def serialize_bot_user(%User{} = bot_user) do
    %{
      id: bot_user.id,
      username: bot_user.username,
      display_name: bot_user.display_name,
      email: bot_user.email,
      bio: bot_user.bio,
      role_ids: Enum.map(bot_user.member_roles || [], & &1.role_id),
      inserted_at: bot_user.inserted_at
    }
  end

  def serialize_message(message) do
    %{
      id: message.id,
      channel_id: message.channel_id,
      author_id: message.author_id,
      body: message.body,
      kind: to_string(message.kind),
      metadata: message.metadata || %{},
      inserted_at: message.inserted_at,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at
    }
  end

  def moderation_response(updated_subject, moderation_case, action) do
    %{
      subject_user_id: updated_subject.id,
      moderation_case_id: moderation_case.id,
      action: action
    }
  end
end
