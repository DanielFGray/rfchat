# Empties the test database and seeds it for the Playwright suite:
#
#     MIX_ENV=test mix run priv/repo/e2e_reset.exs
#
# The ExUnit suite shares this database and empties it again when it starts.

alias Rfchat.Accounts
alias Rfchat.Bootstrap

Rfchat.TestDatabase.truncate!()

Bootstrap.ensure_seed_data!()

{:ok, _user} =
  Accounts.register_user(%{
    email: "e2e@example.com",
    username: "e2e_user",
    display_name: "E2E User",
    password: "supersecurepass"
  })

# Registration never makes an owner; the seed user becomes owner through the
# same operator path a release uses (bin/make-owner).
{:ok, _owner} = Accounts.promote_first_owner("e2e@example.com")
