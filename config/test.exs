import Config

db_username = System.get_env("DB_USERNAME", "postgres")
db_password = System.get_env("DB_PASSWORD", "postgres")
db_host = System.get_env("DB_HOST", "localhost")
db_port = String.to_integer(System.get_env("DB_PORT", "5432"))
db_name = "rfchat_test#{System.get_env("MIX_TEST_PARTITION")}"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :rfchat, Rfchat.Repo,
  username: db_username,
  password: db_password,
  hostname: db_host,
  port: db_port,
  database: db_name,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

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
