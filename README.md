# Rfchat

Rfchat is a self-hostable chat app, with each deployment representing exactly one guild/server.

This repo currently contains the Phoenix bootstrap plus local infrastructure for:

- PostgreSQL for durable app state
- Redis for future ephemeral state (presence, typing, rate limits, fanout helpers)
- Phoenix/Bandit as the core realtime web app
- a first single-guild chat domain with channels, users, and messages
- a minimal LiveView guild shell wired to real database records

## Local bootstrap

1. Copy env vars:

   ```bash
   cp .env.example .env
   ```

2. Start local services:

   ```bash
   docker compose up -d
   ```

3. Install/setup the app:

   ```bash
   mix setup
   ```

4. Start Phoenix:

   ```bash
   mix phx.server
   ```

Then visit [`localhost:4000`](http://localhost:4000).

## Environment

Phoenix reads these env vars in dev/test with sensible defaults:

- `DB_USERNAME`
- `DB_PASSWORD`
- `DB_HOST`
- `DB_PORT`
- `DB_NAME`
- `POOL_SIZE`
- `PORT`
- `REDIS_PORT`
- `REDIS_URL`
- `RFCHAT_GUILD_NAME`

If your machine already has Postgres or Redis running, change `DB_PORT` and/or `REDIS_PORT` in `.env`, and keep `REDIS_URL` aligned with the Redis host port you choose.

The sample `.env` is shell-safe, so commands like `set -a; source .env; set +a` work as expected.

For production, Phoenix also expects:

- `DATABASE_URL`
- `SECRET_KEY_BASE`
- `PHX_HOST`

## Initial architecture direction

Current bootstrap assumption:

- one deployed app instance = one guild
- Phoenix handles HTTP + WebSocket realtime traffic
- Postgres is source of truth
- Redis is reserved for ephemeral coordination, presence, and rate limiting
- keep it as a modular monolith first; split gateway/workers later only if load proves it necessary

## Useful commands

```bash
docker compose up -d
docker compose down
mix ecto.create
mix ecto.migrate
mix test
npm run test:e2e
mix phx.server
mix precommit
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

The Playwright config boots Phoenix on port `4001` in `MIX_ENV=test`, uses an isolated `MIX_BUILD_PATH` for browser runs, resets the test database, builds assets, runs seeds through `mix ecto.reset`, and then executes the browser test.
An additional `priv/repo/e2e_seeds.exs` script provisions a known browser-login user for the smoke test.

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
