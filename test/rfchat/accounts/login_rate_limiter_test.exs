defmodule Rfchat.Accounts.LoginRateLimiterTest do
  use Rfchat.DataCase, async: false

  alias Rfchat.Accounts.LoginRateLimiter

  setup do
    LoginRateLimiter.reset!()
    :ok
  end

  test "concurrent attempts cannot exceed the credential limit" do
    results =
      1..20
      |> Task.async_stream(
        fn _ -> LoginRateLimiter.check_attempt("192.0.2.1", "parallel@example.com") end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &match?({:error, _}, &1)) == 15
  end

  test "successful credential clearing preserves the per-IP count" do
    for index <- 1..20 do
      assert :ok = LoginRateLimiter.check_attempt("192.0.2.2", "account-#{index}@example.com")
    end

    :ok = LoginRateLimiter.clear_attempts("192.0.2.2", "account-1@example.com")

    assert {:error, _retry_after} =
             LoginRateLimiter.check_attempt("192.0.2.2", "another@example.com")
  end
end
