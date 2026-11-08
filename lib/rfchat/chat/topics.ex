defmodule Rfchat.Chat.Topics do
  @moduledoc """
  Owns the PubSub topics for chat events.

  Guild-structure events (`:channel_created`, `:channel_updated`, `:channel_deleted`,
  `:channels_reordered`) go to one guild topic. Message, reaction and typing events go to the
  topic of the channel or thread they happen in, so only processes subscribed to that channel
  receive them. A subscriber is responsible for subscribing only to channels its user can view.

  Broadcasts skip the calling process: the caller has already applied its own change.
  """

  @pubsub Rfchat.PubSub
  @guild_topic "chat:guild"

  def subscribe_guild, do: Phoenix.PubSub.subscribe(@pubsub, @guild_topic)

  def broadcast_guild(event),
    do: Phoenix.PubSub.broadcast_from(@pubsub, self(), @guild_topic, event)

  def broadcast_channel(channel_id, event) do
    Phoenix.PubSub.broadcast_from(@pubsub, self(), channel_topic(channel_id), event)
  end

  @doc """
  Moves the calling process from the channel topics in `subscribed` to those in `wanted`.

  Returns `wanted`, which the caller keeps as its next `subscribed` set. A topic is subscribed at
  most once, because `Phoenix.PubSub` delivers an event once per subscription.
  """
  def sync_channel_subscriptions(%MapSet{} = subscribed, %MapSet{} = wanted) do
    for channel_id <- MapSet.difference(wanted, subscribed) do
      :ok = Phoenix.PubSub.subscribe(@pubsub, channel_topic(channel_id))
    end

    for channel_id <- MapSet.difference(subscribed, wanted) do
      :ok = Phoenix.PubSub.unsubscribe(@pubsub, channel_topic(channel_id))
    end

    wanted
  end

  defp channel_topic(channel_id), do: "chat:channel:" <> channel_id
end
