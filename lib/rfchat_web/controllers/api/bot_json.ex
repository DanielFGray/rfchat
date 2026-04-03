defmodule RfchatWeb.API.BotJSON do
  @moduledoc false

  def index(%{bots: bots}) do
    %{data: Enum.map(bots, &serialize_bot/1)}
  end

  def show(%{bot: bot}) do
    %{data: serialize_bot(bot)}
  end

  def token(%{bot: bot, token: token_info}) do
    %{
      data: %{
        bot: serialize_bot(bot),
        token: %{
          plaintext: token_info.token,
          id: token_info.bot_token.id,
          label: token_info.bot_token.label,
          inserted_at: token_info.bot_token.inserted_at,
          expires_at: token_info.bot_token.expires_at
        }
      }
    }
  end

  def tokens(%{tokens: tokens}) do
    %{data: Enum.map(tokens, &serialize_token/1)}
  end

  defp serialize_bot(bot) do
    %{
      id: bot.id,
      username: bot.username,
      display_name: bot.display_name,
      email: bot.email,
      bio: bot.bio,
      role_ids: Enum.map(bot.member_roles || [], & &1.role_id),
      inserted_at: bot.inserted_at
    }
  end

  defp serialize_token(token) do
    %{
      id: token.id,
      label: token.label,
      inserted_at: token.inserted_at,
      expires_at: token.expires_at,
      revoked_at: token.revoked_at,
      last_used_at: token.last_used_at
    }
  end
end
