import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/rfchat start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :rfchat, RfchatWeb.Endpoint, server: true
end

config :rfchat,
  guild_name: System.get_env("RFCHAT_GUILD_NAME", "RFChat"),
  redis_url: System.get_env("REDIS_URL", "redis://localhost:6379/0"),
  # The platform gives each deploy its own prefix, colon included: `rfchat:` live,
  # `rfchat-staged:` in a staged copy. The Valkey login may touch only keys under it.
  valkey_key_prefix: System.get_env("VALKEY_KEY_PREFIX", "rfchat:")

config :rfchat, RfchatWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# A checkout gets both URLs from `ops dev db up`, which writes them to .env. A deploy
# gets DATABASE_URL from the cartridge's PostgresCredentials secret.
database_url_env = if config_env() == :test, do: "TEST_DATABASE_URL", else: "DATABASE_URL"

config :rfchat, Rfchat.Repo,
  url:
    System.get_env(database_url_env) ||
      raise("""
      environment variable #{database_url_env} is missing.
      In a checkout, run `ops dev db up`, then `set -a; source .env; set +a`.
      """)

if config_env() == :prod do
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :rfchat, Rfchat.Repo,
    # ssl: true,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # A deploy gets the service's public URL, such as its tailnet route, from the cartridge.
  public_url =
    URI.parse(
      System.get_env("PHX_URL") ||
        raise("environment variable PHX_URL is missing, for example https://chat.example.com")
    )

  # The platform gives each deploy, and each staged copy, its own bucket and key.
  fetch_s3_env! = fn name ->
    System.get_env(name) || raise("environment variable #{name} is missing")
  end

  config :rfchat, Rfchat.ObjectStore,
    endpoint: fetch_s3_env!.("S3_ENDPOINT"),
    bucket: fetch_s3_env!.("S3_BUCKET"),
    region: fetch_s3_env!.("S3_REGION"),
    access_key_id: fetch_s3_env!.("S3_ACCESS_KEY_ID"),
    secret_access_key: fetch_s3_env!.("S3_SECRET_ACCESS_KEY")

  # The api login holds no grants and does not inherit the visitor role, so each server
  # connection switches to it. The migrate step logs in as the migration login, which cannot
  # take that role; `Rfchat.Release.migrate/0` starts the Repo without this callback.
  visitor_role = System.get_env("DATABASE_VISITOR")

  if visitor_role do
    quoted_role = ~s("#{String.replace(visitor_role, ~s("), ~s(""))}")

    config :rfchat, Rfchat.Repo,
      after_connect: {Postgrex, :query!, ["SET ROLE #{quoted_role}", []]}
  end

  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      nil -> :check_origin
      "false" -> false
      "" -> :check_origin
      origins -> String.split(origins, ",", trim: true)
    end

  config :rfchat, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :rfchat, RfchatWeb.Endpoint,
    url: [host: public_url.host, port: public_url.port, scheme: public_url.scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :rfchat, RfchatWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :rfchat, RfchatWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
