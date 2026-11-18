# A push to main and `ops stage` build this file from the exported HEAD tree.
# Image tags: https://hub.docker.com/r/hexpm/elixir/tags and https://hub.docker.com/_/debian/tags
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.5
ARG DEBIAN_VERSION=trixie-20260713-slim
ARG NODE_VERSION=22-trixie-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# esbuild resolves the JS imports in assets/js from assets/node_modules.
FROM docker.io/node:${NODE_VERSION} AS node
WORKDIR /app/assets
COPY assets/package.json assets/package-lock.json ./
RUN npm ci

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config before compiling deps, so a config change recompiles them.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

RUN mix compile

COPY assets assets
COPY --from=node /app/assets/node_modules assets/node_modules

RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code.
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

ENV MIX_ENV="prod"

COPY --from=builder /app/_build/${MIX_ENV}/rel/tavern ./

# No USER line: Nomad runs this image under rootless Podman, where container root is already
# the unprivileged host nomad user.
CMD ["/app/bin/server"]
