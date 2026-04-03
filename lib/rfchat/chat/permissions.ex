defmodule Rfchat.Chat.Permissions do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  def can_send_messages?(%Channel{} = channel, %User{} = user) do
    cond do
      thread_channel?(channel) ->
        can_send_messages_in_threads?(channel, user)

      true ->
        not timed_out?(user) and channel_permission?(channel, user, :send_messages) and
          can_view_channel?(channel, user)
    end
  end

  def can_view_channel?(%Channel{} = channel, %User{} = user) do
    cond do
      thread_channel?(channel) ->
        can_view_thread_channel?(channel, user)

      true ->
        channel_permission?(channel, user, :view_channel)
    end
  end

  def can_create_public_threads?(%Channel{} = channel, %User{} = user) do
    thread_host_channel?(channel) and not timed_out?(user) and can_send_messages?(channel, user) and
      channel_permission?(channel, user, :create_public_threads)
  end

  def can_send_messages_in_threads?(%Channel{} = channel, %User{} = user) do
    if thread_channel?(channel) do
      not timed_out?(user) and can_view_thread_channel?(channel, user) and
        channel_permission?(channel, user, :send_messages_in_threads) and
        thread_parent_allows_messages?(channel, user)
    else
      false
    end
  end

  def can_add_reactions?(%Channel{} = channel, %User{} = user) do
    not timed_out?(user) and can_view_channel?(channel, user) and
      channel_permission?(channel, user, :add_reactions)
  end

  def can_manage_messages?(%Channel{} = channel, %User{} = user) do
    can_view_channel?(channel, user) and channel_permission?(channel, user, :manage_messages)
  end

  def can_mention_everyone?(%Channel{} = channel, %User{} = user) do
    can_view_channel?(channel, user) and channel_permission?(channel, user, :mention_everyone)
  end

  def can_manage_emojis_and_stickers?(%User{} = user) do
    permissions =
      user
      |> Repo.preload([:membership, member_roles: :role])
      |> Authorization.base_permissions(default_role())

    Authorization.has_permission?(permissions, :manage_emojis_and_stickers) or
      Authorization.has_permission?(permissions, :administrator)
  end

  def timed_out?(%User{membership: %{timeout_until: timeout_until}})
      when not is_nil(timeout_until) do
    DateTime.compare(timeout_until, DateTime.utc_now()) == :gt
  end

  def timed_out?(%User{}), do: false

  def moderation_permission?(%User{} = user, permission_name) do
    permissions =
      user
      |> Repo.preload([:membership, member_roles: :role])
      |> Authorization.base_permissions(default_role())

    Authorization.has_permission?(permissions, permission_name) or
      Authorization.has_permission?(permissions, :administrator)
  end

  def default_role do
    Repo.get_by(Role, is_default: true)
  end

  def thread_channel?(%Channel{kind: kind}),
    do: kind in [:thread_public, :thread_private, :thread_announcement]

  def thread_host_channel?(%Channel{kind: kind}), do: kind in [:text, :announcement, :forum]

  def thread_parent_channel(%Channel{} = channel) do
    channel = Repo.preload(channel, [:parent_channel])
    channel.parent_channel
  end

  def can_view_thread_channel?(%Channel{} = channel, %User{} = user) do
    case thread_parent_channel(channel) do
      %Channel{} = parent_channel ->
        can_view_channel?(parent_channel, user) and
          channel_permission?(channel, user, :view_channel)

      _ ->
        false
    end
  end

  def thread_parent_allows_messages?(%Channel{} = channel, %User{} = user) do
    case thread_parent_channel(channel) do
      %Channel{} = parent_channel -> can_send_messages?(parent_channel, user)
      _ -> false
    end
  end

  def channel_permission?(%Channel{} = channel, %User{} = user, permission_name) do
    channel = Repo.preload(channel, [:permission_overwrites])
    user = Repo.preload(user, [:membership, member_roles: :role])

    Authorization.channel_permissions(user, channel, default_role())
    |> Authorization.has_permission?(permission_name)
  end
end
