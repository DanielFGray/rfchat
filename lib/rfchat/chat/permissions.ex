defmodule Rfchat.Chat.Permissions do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Rfchat.Chat.Authorization
  alias Rfchat.Chat.Channel
  alias Rfchat.Chat.Role
  alias Rfchat.Chat.User
  alias Rfchat.Repo

  @default_role_cache_key {__MODULE__, :default_role}

  @doc """
  The member as the database holds them now, with membership and roles, or nil when the user
  is deleted. Authorization for a write reads this, because a session's user struct can be
  stale after a role change, a demotion or a deactivation.
  """
  def current_member(user_id) do
    User
    |> where([user], user.id == ^user_id and is_nil(user.deleted_at))
    |> preload([:membership, member_roles: :role])
    |> Repo.one()
  end

  @doc "The member's server-wide permissions as the database holds them now."
  def current_permissions(%User{id: user_id}) do
    case current_member(user_id) do
      nil -> 0
      member -> Authorization.base_permissions(member, default_role())
    end
  end

  def can_send_messages?(%Channel{} = channel, %User{} = user) do
    can_send_messages?(channel, user, default_role())
  end

  def can_send_messages?(%Channel{} = channel, %User{} = user, default_role) do
    cond do
      thread_channel?(channel) ->
        can_send_messages_in_threads?(channel, user, default_role)

      true ->
        not timed_out?(user) and channel_permission?(channel, user, :send_messages, default_role) and
          can_view_channel?(channel, user, default_role)
    end
  end

  def can_view_channel?(%Channel{} = channel, %User{} = user) do
    can_view_channel?(channel, user, default_role())
  end

  def can_view_channel?(%Channel{} = channel, %User{} = user, default_role) do
    cond do
      thread_channel?(channel) ->
        can_view_thread_channel?(channel, user, default_role)

      true ->
        channel_permission?(channel, user, :view_channel, default_role)
    end
  end

  def can_create_public_threads?(%Channel{} = channel, %User{} = user) do
    default_role = default_role()

    thread_host_channel?(channel) and not timed_out?(user) and
      can_send_messages?(channel, user, default_role) and
      channel_permission?(channel, user, :create_public_threads, default_role)
  end

  def can_send_messages_in_threads?(%Channel{} = channel, %User{} = user) do
    can_send_messages_in_threads?(channel, user, default_role())
  end

  def can_send_messages_in_threads?(%Channel{} = channel, %User{} = user, default_role) do
    if thread_channel?(channel) do
      not timed_out?(user) and can_view_thread_channel?(channel, user, default_role) and
        channel_permission?(channel, user, :send_messages_in_threads, default_role) and
        thread_parent_allows_messages?(channel, user, default_role)
    else
      false
    end
  end

  def can_add_reactions?(%Channel{} = channel, %User{} = user) do
    default_role = default_role()

    not timed_out?(user) and can_view_channel?(channel, user, default_role) and
      channel_permission?(channel, user, :add_reactions, default_role)
  end

  def can_manage_messages?(%Channel{} = channel, %User{} = user) do
    default_role = default_role()

    can_view_channel?(channel, user, default_role) and
      channel_permission?(channel, user, :manage_messages, default_role)
  end

  def can_mention_everyone?(%Channel{} = channel, %User{} = user) do
    default_role = default_role()

    can_view_channel?(channel, user, default_role) and
      channel_permission?(channel, user, :mention_everyone, default_role)
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
    if Application.get_env(:rfchat, :cache_default_role, true) do
      case :persistent_term.get(@default_role_cache_key, :missing) do
        %Role{} = role ->
          role

        _missing_or_nil ->
          load_default_role()
      end
    else
      Repo.get_by(Role, is_default: true)
    end
  end

  def thread_channel?(%Channel{kind: kind}),
    do: kind in [:thread_public, :thread_private, :thread_announcement]

  def thread_host_channel?(%Channel{kind: kind}), do: kind in [:text, :announcement, :forum]

  def thread_parent_channel(%Channel{} = channel) do
    channel = Repo.preload(channel, [:parent_channel])
    channel.parent_channel
  end

  def can_view_thread_channel?(%Channel{} = channel, %User{} = user) do
    can_view_thread_channel?(channel, user, default_role())
  end

  def can_view_thread_channel?(%Channel{} = channel, %User{} = user, default_role) do
    case thread_parent_channel(channel) do
      %Channel{} = parent_channel ->
        can_view_channel?(parent_channel, user, default_role) and
          channel_permission?(channel, user, :view_channel, default_role)

      _ ->
        false
    end
  end

  def thread_parent_allows_messages?(%Channel{} = channel, %User{} = user) do
    thread_parent_allows_messages?(channel, user, default_role())
  end

  def thread_parent_allows_messages?(%Channel{} = channel, %User{} = user, default_role) do
    case thread_parent_channel(channel) do
      %Channel{} = parent_channel -> can_send_messages?(parent_channel, user, default_role)
      _ -> false
    end
  end

  def channel_permission?(%Channel{} = channel, %User{} = user, permission_name) do
    channel_permission?(channel, user, permission_name, default_role())
  end

  def channel_permission?(%Channel{} = channel, %User{} = user, permission_name, default_role) do
    channel = maybe_preload_channel_permission_overwrites(channel)

    Authorization.channel_permissions(user, channel, default_role)
    |> Authorization.has_permission?(permission_name)
  end

  defp maybe_preload_channel_permission_overwrites(%Channel{} = channel) do
    if Ecto.assoc_loaded?(channel.permission_overwrites) do
      channel
    else
      Repo.preload(channel, [:permission_overwrites])
    end
  end

  defp load_default_role do
    case Repo.get_by(Role, is_default: true) do
      %Role{} = role ->
        :persistent_term.put(@default_role_cache_key, role)
        role

      nil ->
        nil
    end
  end
end
