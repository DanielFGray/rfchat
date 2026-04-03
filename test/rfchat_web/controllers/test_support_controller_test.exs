defmodule RfchatWeb.TestSupportControllerTest do
  use RfchatWeb.ConnCase

  import Rfchat.ChatFixtures

  alias Rfchat.Bootstrap

  setup do
    previous = System.get_env("ENABLE_TEST_SUPPORT_COMMANDS")
    System.put_env("ENABLE_TEST_SUPPORT_COMMANDS", "1")

    on_exit(fn ->
      if previous do
        System.put_env("ENABLE_TEST_SUPPORT_COMMANDS", previous)
      else
        System.delete_env("ENABLE_TEST_SUPPORT_COMMANDS")
      end
    end)

    :ok
  end

  describe "upsert_user" do
    test "creates a safe test user", %{conn: conn} do
      conn =
        get(conn, ~p"/api/testing/command", %{
          command: "upsert_user",
          payload: Jason.encode!(%{email: "test_api@example.com", username: "test_api_user"})
        })

      assert %{"data" => %{"user" => %{"email" => "test_api@example.com"}}} =
               json_response(conn, 200)
    end

    test "is idempotent for existing users", %{conn: conn} do
      params = %{
        command: "upsert_user",
        payload: Jason.encode!(%{email: "test_idem@example.com", username: "test_idem"})
      }

      conn1 = get(conn, ~p"/api/testing/command", params)
      assert %{"data" => %{"user" => %{"id" => id}}} = json_response(conn1, 200)

      conn2 = get(build_conn(), ~p"/api/testing/command", params)
      assert %{"data" => %{"user" => %{"id" => ^id}}} = json_response(conn2, 200)
    end

    test "rejects unsafe usernames", %{conn: conn} do
      conn =
        get(conn, ~p"/api/testing/command", %{
          command: "upsert_user",
          payload: Jason.encode!(%{email: "bad@example.com", username: "unsafe"})
        })

      assert %{"error" => %{"message" => message}} = json_response(conn, 500)
      assert message =~ "test usernames"
    end

    test "rejects unsafe email domains", %{conn: conn} do
      conn =
        get(conn, ~p"/api/testing/command", %{
          command: "upsert_user",
          payload: Jason.encode!(%{email: "test_user@evil.com", username: "test_evil"})
        })

      assert %{"error" => %{"message" => message}} = json_response(conn, 500)
      assert message =~ "@example.com"
    end
  end

  describe "set_server_name" do
    test "updates server branding", %{conn: conn} do
      Bootstrap.ensure_seed_data!()
      user_fixture(%{email: "test_owner_ss@example.com", username: "test_owner_ss"})

      conn =
        get(conn, ~p"/api/testing/command", %{
          command: "set_server_name",
          payload: Jason.encode!(%{name: "Test Orbit"})
        })

      assert %{"data" => %{"server" => %{"name" => "Test Orbit"}}} = json_response(conn, 200)
    end
  end

  describe "clear_test_users" do
    test "removes test users and their messages", %{conn: conn} do
      Bootstrap.ensure_seed_data!()

      get(conn, ~p"/api/testing/command", %{
        command: "upsert_user",
        payload: Jason.encode!(%{email: "test_cleanup@example.com", username: "test_cleanup"})
      })

      conn =
        get(build_conn(), ~p"/api/testing/command", %{command: "clear_test_users"})

      assert %{"data" => %{"success" => true, "deleted_users" => count}} =
               json_response(conn, 200)

      assert count >= 1
    end
  end

  describe "login" do
    test "redirects with valid session", %{conn: conn} do
      conn =
        get(conn, ~p"/api/testing/command", %{
          command: "login",
          payload:
            Jason.encode!(%{
              email: "test_login@example.com",
              username: "test_login",
              next: "/settings"
            })
        })

      assert redirected_to(conn) == "/settings"
      assert get_session(conn, :user_token)
    end

    test "defaults redirect to /", %{conn: conn} do
      conn =
        get(conn, ~p"/api/testing/command", %{
          command: "login",
          payload: Jason.encode!(%{email: "test_login2@example.com", username: "test_login2"})
        })

      assert redirected_to(conn) == "/"
    end
  end

  describe "error handling" do
    test "returns stack trace on failure", %{conn: conn} do
      conn =
        get(conn, ~p"/api/testing/command", %{command: "nonexistent_command"})

      assert %{"error" => %{"message" => message, "stack" => stack}} =
               json_response(conn, 500)

      assert message =~ "not understood"
      assert is_binary(stack)
      assert stack =~ "TestSupport"
    end

    test "fails when ENABLE_TEST_SUPPORT_COMMANDS is not set", %{conn: conn} do
      System.delete_env("ENABLE_TEST_SUPPORT_COMMANDS")

      conn =
        get(conn, ~p"/api/testing/command", %{command: "get_server_branding"})

      assert %{"error" => %{"message" => message}} = json_response(conn, 500)
      assert message =~ "disabled"
    end
  end
end
