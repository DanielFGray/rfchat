import Config

# config/runtime.exs sets the database URL from TEST_DATABASE_URL.
config :rfchat, Rfchat.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  # `ops dev db` caps each dev login at 8 connections.
  pool_size: 8

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :rfchat, RfchatWeb.Endpoint,
  url: [host: "127.0.0.1", port: 4001],
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  secret_key_base: "HHDOlzXeOcVQj1LibdiPwgSjX59e5Xvpm+Znp1E7VvaoenUUw0IxQFik/sVcwL/J",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Requests go to an in-memory bucket through Req's plug transport; signing still runs.
config :rfchat, Rfchat.ObjectStore,
  endpoint: "http://object-store.test",
  bucket: "rfchat-test",
  region: "us-east-1",
  access_key_id: "test",
  secret_access_key: "test",
  req_options: [plug: Rfchat.TestObjectStore, retry: false]

config :rfchat, :defer_guild_live_hydration, false
config :rfchat, :cache_default_role, false
