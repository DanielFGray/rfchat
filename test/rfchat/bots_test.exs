defmodule Rfchat.BotsTest do
  use Rfchat.DataCase

  import Rfchat.ChatFixtures

  alias Rfchat.Bots
  alias Rfchat.Chat.PermissionBits

  describe "bot tokens and command registry" do
    test "creates bot users with roles and one-time tokens" do
      actor = user_fixture(%{email: "bot-owner@example.com", username: "bot_owner"})

      role =
        role_fixture(%{
          name: "Bot Speaker",
          permissions: PermissionBits.combine([:send_messages])
        })

      {:ok, bot_user} =
        Bots.create_bot(
          %{
            "display_name" => "Helper Bot",
            "username" => "helper_bot",
            "email" => "helper-bot@example.com",
            "role_ids" => [role.id]
          },
          actor
        )

      assert bot_user.bot
      assert Enum.any?(bot_user.member_roles, &(&1.role_id == role.id))

      {:ok, %{token: token}} = Bots.create_bot_token(bot_user, %{"label" => "primary"}, actor)
      assert {:ok, bot_scope} = Bots.get_bot_scope_by_token(token)
      assert bot_scope.bot_user.id == bot_user.id
    end

    test "executes registered message command" do
      actor = user_fixture(%{email: "bot-cmd-owner@example.com", username: "bot_cmd_owner"})

      role =
        role_fixture(%{
          name: "Bot Speaker",
          permissions: PermissionBits.combine([:view_channel, :send_messages])
        })

      channel = channel_fixture(%{name: "Bots", slug: unique_slug()})
      bot_user = bot_fixture(actor, %{"role_ids" => [role.id]})

      {:ok, %{message: message}} =
        Bots.execute_command(
          "send_message",
          %Bots.BotScope{
            bot_user: bot_user,
            roles: Enum.map(bot_user.member_roles, & &1.role),
            base_permissions: PermissionBits.combine([:view_channel, :send_messages])
          },
          %{"channel_id" => channel.id, "body" => "hello from bot"}
        )

      assert message.body == "hello from bot"
      assert message.channel_id == channel.id
    end

    test "get_bot_user/1 does not return non-bot users" do
      user = user_fixture(%{email: "human@example.com", username: "human_user"})

      assert Bots.get_bot_user(user.id) == nil
    end

    test "send_message returns invalid_params for malformed channel ids" do
      actor =
        user_fixture(%{email: "bot-bad-channel-owner@example.com", username: "bot_bad_owner"})

      bot_user = bot_fixture(actor)

      assert {:error, :invalid_params} =
               Bots.command_send_message(
                 %Bots.BotScope{bot_user: bot_user, roles: [], base_permissions: 0},
                 %{"channel_id" => "not-a-uuid", "body" => "hello"}
               )
    end
  end
end
