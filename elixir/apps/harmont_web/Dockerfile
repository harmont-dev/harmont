# syntax=docker/dockerfile:1
# Production image for the Harmont Elixir umbrella.
#
# This builds the umbrella OTP release `:harmont` (defined in elixir/mix.exs:
# releases: [harmont: [applications: [harmont_core, harmont_engine,
# harmont_gh_app, harmont_web]]]). A single image runs the whole platform on
# the MIG — web/api + executor + gh_app — serving HTTP on port 4000. The MIG
# pulls it as harmont-executor:${deploy_version}.
#
# Build context MUST be the repo root (the top-level proto/ sources are copied
# in alongside the elixir/ umbrella):
#
#   docker build -f elixir/apps/harmont_web/Dockerfile \
#     -t harmont-executor:dev .
#
# Runtime config (config/runtime.exs) reads secrets from env at boot; the MIG
# injects HARMONT_DATABASE_URL, SECRET_KEY_BASE, FREESTYLE_API_KEY,
# HONEYCOMB_API_KEY, PHX_SERVER, PORT, the OAuth/Stripe/Resend creds, etc.

# ---------------------------------------------------------------------------
# Stage 1: build
# ---------------------------------------------------------------------------
# Plan specified an OTP-28 base, but OTP 28 images are not published on Docker
# Hub yet. Pinned to the newest known-good Elixir 1.19.5 + OTP 26.2.5.8 +
# bookworm-slim image.
FROM hexpm/elixir:1.19.5-erlang-26.2.5.8-debian-bookworm-20260518-slim AS build

ENV MIX_ENV=prod

# protobuf-compiler provides `protoc`, which `mix protobuf.generate` (via
# apps/harmont_engine/proto/gen.sh) shells out to. protobuf_generate ships a
# pure-Elixir code generator, so no protoc-gen-elixir plugin binary is needed.
RUN apt-get update -y \
 && apt-get install -y build-essential git protobuf-compiler \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

# Copy the whole umbrella (root mix.exs/mix.lock, config/, apps/). A flat
# COPY keeps the path-deps and in_umbrella resolution intact; umbrella layer
# caching by app is brittle, so we favour correctness here.
COPY elixir/ ./

# The agent protobuf stubs (apps/harmont_engine/lib/harmont/proto/*.pb.ex)
# are gitignored and regenerated at build time. proto/gen.sh defaults
# PROTO_DIR to ../../../proto relative to apps/harmont_engine/, which
# resolves to /proto here — so copy the top-level proto sources to /proto.
COPY proto /proto

# Register the private Oban Pro Hex repo before fetching deps. oban_pro is
# licensed (mix.exs: `{:oban_pro, repo: "oban"}`); without this repo, deps.get
# fails with `Unknown repository "oban"`. The license/auth key is injected as a
# BuildKit secret (--secret id=oban_auth_key, sourced from your secret store)
# so it never lands in an image layer or `docker history`. `hex.repo
# add` writes it into this build stage's hex.config only — the final runtime
# image (Stage 2) copies just the release, never the build stage's HOME.
RUN --mount=type=secret,id=oban_auth_key \
    mix hex.repo add oban https://repo.oban.pro \
      --fetch-public-key SHA256:4/OSKi0NRF91QVVXlGAhb/BIMLnK8NHcx/EWs+aIWPc \
      --auth-key "$(cat /run/secrets/oban_auth_key)"

RUN mix deps.get --only prod

# `mix proto.gen` -> `cmd --app harmont_engine bash proto/gen.sh`. The
# protobuf.generate task declares `@requirements ["app.config"]`, so it
# evaluates config/runtime.exs first; the prod branch there calls
# System.fetch_env! for real secrets that are absent at build time. Codegen
# uses none of them, so pass throwaway placeholders for THIS layer only (they
# do not persist into the image and are not the real release config, which is
# read from env at boot).
RUN HARMONT_DATABASE_URL=build SECRET_KEY_BASE=build \
    HARMONT_LOG_TOKEN_SECRET=build HONEYCOMB_API_KEY=build \
    FREESTYLE_API_KEY=build RESEND_API_KEY=build \
    GOOGLE_OAUTH_CLIENT_ID=build GOOGLE_OAUTH_CLIENT_SECRET=build \
    GITHUB_OAUTH_CLIENT_ID=build GITHUB_OAUTH_CLIENT_SECRET=build \
    STRIPE_SECRET_KEY=build STRIPE_WEBHOOK_SECRET=build \
    HARMONT_OBAN_ENCRYPTION_KEY=build \
    HARMONT_OBAN_DASHBOARD_USER=build HARMONT_OBAN_DASHBOARD_PASSWORD=build \
    RUNLOOP_API_KEY=build \
    HARMONT_CLOAK_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
    mix proto.gen

RUN mix compile
RUN mix release harmont --overwrite

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS app

RUN apt-get update -y \
 && apt-get install -y libstdc++6 openssl libncurses6 ca-certificates locales \
 && rm -rf /var/lib/apt/lists/*

# Set the runtime locale to UTF-8 so the BEAM handles Unicode correctly.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

COPY --from=build /app/_build/prod/rel/harmont ./

ENV HOME=/app

EXPOSE 4000

# Run Ecto migrations, then start the OTP release. Shell form is intentional:
# we need `&&` to chain migrate -> start. PHX_SERVER (set by the MIG) makes the
# Phoenix endpoint serve; runtime.exs is read at boot.
# hadolint ignore=DL3025
CMD ["/bin/sh", "-c", "bin/harmont eval \"Harmont.Release.migrate()\" && exec bin/harmont start"]
