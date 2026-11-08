# Rfchat

Rfchat is a self-hostable chat app, with each deployment representing exactly one guild/server.

This repo currently contains the Phoenix bootstrap plus local infrastructure for:

- PostgreSQL for durable app state
- Valkey for ephemeral state (presence, typing, rate limits, fanout helpers)
- Phoenix/Bandit as the core realtime web app
- a first single-guild chat domain with channels, users, and messages
- a minimal LiveView guild shell wired to real database records

## Local bootstrap

Postgres comes from the platform (`server-ansible`), which reads `cartridge.json`. Valkey runs locally in Docker.

1. Copy the env file, then add the database URLs to it:

   ```bash
   cp .env.example .env
   ops dev db up
   ```

   `ops dev db up` creates `rfchat_dev` and `rfchat_dev_test` and writes `DATABASE_URL`, `TEST_DATABASE_URL` and `DATABASE_VISITOR` to `.env`.

2. Start Valkey and load the env:

   ```bash
   docker compose up -d
   set -a; source .env; set +a
   ```

3. Install the app, run the migrations and add the seed data:

   ```bash
   mix setup
   ```

4. Start Phoenix:

   ```bash
   mix phx.server
   ```

Then visit [`localhost:4000`](http://localhost:4000).

The dev logins cannot create or drop databases. To start again from an empty dev database, run `ops dev db reset rfchat_dev`.

## Environment

In dev and test, Phoenix reads:

- `DATABASE_URL`, `TEST_DATABASE_URL`, `DATABASE_VISITOR`: written by `ops dev db up`
- `REDIS_URL`, `REDIS_PORT`: the local Valkey
- `S3_PORT`: the local S3 store (SeaweedFS) that holds uploads; `config/dev.exs` points at it
- `PORT`, `POOL_SIZE`, `RFCHAT_GUILD_NAME`

A deploy gets its environment from `cartridge.json`: `DATABASE_URL`, `REDIS_URL`, `SECRET_KEY_BASE`, `DATABASE_VISITOR` (the role each server connection switches to with `SET ROLE`), `PHX_URL` (the service's route URL), `VALKEY_KEY_PREFIX`, and the upload bucket: `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`. Tests keep the bucket in memory.

## Deploy

`ops release` builds the `Dockerfile` from the committed `HEAD` and deploys the image as `cartridge.json` declares. Its migrate step, `/app/bin/migrate`, runs the migrations and adds the seed data before the server starts. The platform generates the session secret, `SECRET_KEY_BASE`, on the first deploy or stage and keeps it at `secret/data/rfchat/generated`; a staged copy reads the live value. The bucket comes from the platform's object store (`"objectStore": {}` in `cartridge.json`). The migrate step also gets the bucket key, because it loads `config/runtime.exs`, which requires the bucket variables in prod. A staged copy uses the live bucket with its own key, so deleting an upload in a staged copy deletes the live file.

## Initial architecture direction

Current bootstrap assumption:

- one deployed app instance = one guild
- Phoenix handles HTTP + WebSocket realtime traffic
- Postgres is source of truth
- Valkey is used for ephemeral coordination, presence, and rate limiting
- keep it as a modular monolith first; split gateway/workers later only if load proves it necessary

## Useful commands

```bash
ops dev db up                  # create the dev and test databases, write their URLs to .env
ops dev db reset rfchat_dev    # empty the dev database
docker compose up -d           # start Valkey
mix ecto.migrate
mix test
npm run test:e2e
mix phx.server
mix precommit
ops secret list                # each secret the cartridge reads: set or MISSING
ops release                    # build and deploy the committed HEAD
```

## Playwright E2E

Rfchat now includes a Playwright smoke test that proves the main chat path works end to end:

- log in
- open the guild shell
- switch to `engineering`
- send a persisted rich chat message with markdown, code blocks, and link rendering

Run it with:

```bash
npm run test:e2e
```

The Playwright config boots Phoenix on port `4001` in `MIX_ENV=test` with an isolated `MIX_BUILD_PATH`. Before the server starts, it runs the migrations and `priv/repo/e2e_reset.exs`, which empties every table of the test database, adds the seed data and a known browser-login user, and then builds the assets. The ExUnit suite uses the same database and empties it in `test/test_helper.exs` before it runs, so the two suites do not depend on each other's cleanup.

## Current app shape

The root route now serves a minimal guild chat shell:

- seeded channels: `general`, `engineering`, `random`
- owners can open an in-app channel manager to create/edit categories and text channels
- channel list now renders grouped sections when channels belong to categories
- seeded system poster: `rfchat_system`
- first registered account becomes the server owner
- default `@everyone` role grants baseline channel visibility + messaging
- channel switching via LiveView patch params
- local message posting persisted to Postgres
- markdown rendering with code blocks and simple rich link cards in the transcript
- rich composer toolbar for bold, italic, inline code, code blocks, mentions, and slash commands
- permission-aware transcript/composer UX for sending, reacting, deleting, and role-mention guidance
- admins with emoji permission can upload/delete custom emoji and everyone can use them in a searchable full Unicode + custom reaction picker

Login is rate limited, session metadata stores IP/user-agent, and channel rendering/posting now respects membership + permission checks.

This is intentionally barebones infra, not polished product UX.

## Learn more

- Official website: https://www.phoenixframework.org/
- Guides: https://hexdocs.pm/phoenix/overview.html
- Docs: https://hexdocs.pm/phoenix
- Forum: https://elixirforum.com/c/phoenix-forum
- Source: https://github.com/phoenixframework/phoenix
