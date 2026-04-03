defmodule Rfchat.Bootstrap do
  @moduledoc """
  Bootstrap helpers for provisioning a fresh single-guild rfchat instance.
  """

  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Message
  alias Rfchat.Chat.PermissionBits
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.ServerSettings
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  @default_seed_username "rfchat_system"
  @default_seed_display_name "RFChat System"
  @default_seed_permissions [
    :view_channel,
    :send_messages,
    :create_public_threads,
    :send_messages_in_threads,
    :embed_links,
    :attach_files,
    :add_reactions
  ]

  def ensure_seed_data! do
    Repo.transaction(fn ->
      user =
        ensure_system_user!()

      default_role = ensure_default_role!()

      channels =
        [
          %{name: "General", slug: "general", position: 0, topic: "Default lobby for the guild"},
          %{
            name: "Engineering",
            slug: "engineering",
            position: 1,
            topic: "Build notes and technical chatter"
          },
          %{name: "Random", slug: "random", position: 2, topic: "Off-topic but still useful"}
        ]
        |> Enum.map(&ensure_channel!/1)

      general_channel = Enum.find(channels, &(&1.slug == "general"))

      ensure_welcome_message!(general_channel, user)
      ensure_server_settings!()

      %{system_user: user, default_role: default_role, channels: channels}
    end)
    |> case do
      {:ok, result} -> result
      {:error, _step, reason, _changes} -> raise reason
    end
  end

  defp ensure_system_user! do
    now = DateTime.utc_now()

    %User{}
    |> User.changeset(%{
      email: "system@rfchat.local",
      username: @default_seed_username,
      display_name: @default_seed_display_name,
      bot: true,
      system: true,
      bio: "System actor for bootstrap and service messages."
    })
    |> Repo.insert!(
      on_conflict: [
        set: [
          username: @default_seed_username,
          display_name: @default_seed_display_name,
          bot: true,
          system: true,
          bio: "System actor for bootstrap and service messages.",
          updated_at: now
        ]
      ],
      conflict_target: :email,
      returning: true
    )
  end

  defp ensure_default_role! do
    now = DateTime.utc_now()

    %Role{}
    |> Role.changeset(%{
      name: "@everyone",
      description: "Default permissions for all members of this single guild.",
      permissions: PermissionBits.combine(@default_seed_permissions),
      position: 0,
      mentionable: false,
      hoist: false,
      managed: true,
      is_default: true
    })
    |> Repo.insert!(
      on_conflict: [
        set: [
          name: "@everyone",
          description: "Default permissions for all members of this single guild.",
          permissions: PermissionBits.combine(@default_seed_permissions),
          position: 0,
          mentionable: false,
          hoist: false,
          managed: true,
          updated_at: now
        ]
      ],
      conflict_target: {:unsafe_fragment, "(is_default) WHERE is_default = true"},
      returning: true
    )
  end

  defp ensure_channel!(attrs) do
    now = DateTime.utc_now()

    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert!(
      on_conflict: [
        set: [
          name: attrs.name,
          position: attrs.position,
          topic: attrs.topic,
          updated_at: now
        ]
      ],
      conflict_target: :slug,
      returning: true
    )
  end

  defp ensure_welcome_message!(channel, user) do
    %Message{channel_id: channel.id, author_id: user.id}
    |> Message.changeset(%{
      body: "Welcome to RFChat. Register the first account to become this server's owner.",
      kind: :system,
      nonce: "bootstrap:welcome"
    })
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(channel_id, nonce) WHERE nonce IS NOT NULL"}
    )
  end

  defp ensure_server_settings! do
    now = DateTime.utc_now()

    %ServerSettings{}
    |> ServerSettings.changeset(%{
      singleton: true,
      name: Application.get_env(:rfchat, :guild_name, "RFChat")
    })
    |> Repo.insert!(
      on_conflict: [
        set: [
          name: Application.get_env(:rfchat, :guild_name, "RFChat"),
          updated_at: now
        ]
      ],
      conflict_target: :singleton,
      returning: true
    )
  end
end
