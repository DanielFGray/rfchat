defmodule Rfchat.LockTestHelpers do
  @moduledoc """
  Helpers for tests that prove a write waits on a row lock. The sandbox shares one connection, so
  these tests use real connections that commit. A holder takes a lock in an open transaction, the
  writes under test queue behind it, and the test releases the holder once `pg_locks` shows them
  waiting.
  """

  import ExUnit.Assertions

  alias Rfchat.Repo

  # Backends blocked on a lock. The first waiter on a row waits on the holder's transaction id, a
  # later one on the row's tuple lock, and a waiter on an advisory lock on that lock. Every role may
  # read `pg_locks`; `pg_stat_activity` hides other sessions' wait events from a non-superuser.
  @waiting_sql """
  SELECT count(*) FROM pg_locks
  WHERE NOT granted AND locktype IN ('transactionid', 'tuple', 'advisory')
    AND pid <> pg_backend_pid()
  """

  @doc """
  Runs `fun` inside a transaction on its own connection and keeps the transaction open until
  `commit/1`. Returns the holder process, which `commit/1` waits on.
  """
  def hold_open(fun) do
    parent = self()

    holder =
      spawn_link(fn ->
        on_own_connection(fn ->
          result =
            Repo.transaction(fn ->
              send(parent, {:held, self(), fun.()})
              receive do: (:commit -> :ok)
            end)

          send(parent, {:committed, self(), result})
        end)
      end)

    assert_receive {:held, ^holder, _decision}, 10_000
    holder
  end

  @doc "Commits a holder from `hold_open/1` and waits for the commit."
  def commit(holder) do
    send(holder, :commit)
    assert_receive {:committed, ^holder, {:ok, _}}, 10_000
  end

  @doc """
  Polls until at least `count` backends wait on a lock. Each poll is a network round trip, so the
  bound is in attempts rather than a sleep.
  """
  def await_waiters(count, attempts \\ 100)
  def await_waiters(count, 0), do: flunk("fewer than #{count} backends waited on a lock")

  def await_waiters(count, attempts) do
    case Repo.query!(@waiting_sql).rows do
      [[waiting]] when waiting >= count -> :ok
      _fewer -> await_waiters(count, attempts - 1)
    end
  end

  @doc """
  Checks out a connection of its own for the calling process, then runs `fun`. The test process
  already holds one from the sandbox setup, so only a new process gets a separate connection.
  """
  def on_own_connection(fun) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    fun.()
  end
end
