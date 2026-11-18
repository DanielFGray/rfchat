defmodule Rfchat.Bots.SerializerTest do
  use Rfchat.DataCase, async: false

  import Rfchat.ChatFixtures

  alias Rfchat.Accounts.Scope
  alias Rfchat.Bots.Serializer
  alias Rfchat.Chat

  test "serialize_message reads nothing from a message the scoped read returned" do
    owner = owner_fixture(%{email: "ser-owner@example.com", username: "ser_owner"})
    channel = channel_fixture(%{name: "Serial", slug: unique_slug()})
    sent = message_fixture(channel, owner, %{body: "serialize me"})

    message = Chat.get_message(%Scope{user_id: owner.id}, sent.id)

    {serialized, queries} = count_queries(fn -> Serializer.serialize_message(message) end)

    assert queries == 0
    assert serialized.body == "serialize me"
    assert serialized.author.username == owner.username
    assert serialized.channel.id == channel.id
  end

  test "serialize_thread reads nothing from a thread loaded with its parent and starter" do
    owner = owner_fixture(%{email: "ser-thread-owner@example.com", username: "ser_thread_owner"})
    channel = channel_fixture(%{name: "Serial Threads", slug: unique_slug()})
    starter = message_fixture(channel, owner, %{body: "start a thread"})
    _thread = thread_fixture(channel, starter, owner)

    thread = Chat.get_thread_for_starter_message(%Scope{user_id: owner.id}, starter.id)

    {serialized, queries} = count_queries(fn -> Serializer.serialize_thread(thread) end)

    assert queries == 0
    assert serialized.parent_channel.id == channel.id
    assert serialized.starter_message.id == starter.id
    assert serialized.starter_message.author.username == owner.username
  end

  # Runs `fun` and returns its result with the number of Repo queries it ran.
  defp count_queries(fun) do
    handler = "serializer-query-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:rfchat, :repo, :query],
        fn _event, _measurements, _metadata, _config -> send(parent, :repo_query) end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, drain_queries(0)}
  end

  defp drain_queries(count) do
    receive do
      :repo_query -> drain_queries(count + 1)
    after
      0 -> count
    end
  end
end
