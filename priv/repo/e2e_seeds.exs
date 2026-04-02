alias Rfchat.Accounts
alias Rfchat.Bootstrap

Bootstrap.ensure_seed_data!()

unless Accounts.get_user_by_email("e2e@example.com") do
  {:ok, _user} =
    Accounts.register_user(%{
      email: "e2e@example.com",
      username: "e2e_user",
      display_name: "E2E User",
      password: "supersecurepass"
    })
end
