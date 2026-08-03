# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :harmont_core,
  ecto_repos: [Harmont.Repo],
  generators: [binary_id: true]

# Graceful-shutdown drain window. On SIGTERM, Harmont.Drain flips /healthz to 503
# and waits this long before System.stop/0, so the GCE LB health check fails and
# the LB de-registers this backend BEFORE we stop accepting. Tune to comfortably
# exceed the LB health-check fail window (checkIntervalSec * unhealthyThreshold).
config :harmont_core, :drain_grace_ms, 20_000

# Source/artifact blob storage. The active adapter is read from
# `:harmont, :storage`; dev/test default to the filesystem-backed
# `Harmont.Storage.Local` (no GCP creds needed), prod swaps in
# `Harmont.Storage.Gcs` via config/runtime.exs.
config :harmont, :storage, Harmont.Storage.Local

config :harmont_core, Harmont.Repo,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec],
  # pin the telemetry prefix so OpentelemetryEcto.setup/1 (Telemetry) matches it
  telemetry_prefix: [:harmont_core, :repo]

# Oban (durable orchestration backbone — REVISION 2026-05-24b/c)
config :harmont_core, Oban,
  repo: Harmont.Repo,
  engine: Oban.Pro.Engines.Smart,
  notifier: Oban.Notifiers.Postgres,
  peer: Oban.Peers.Database,
  plugins: [
    # DynamicQueues OWNS the queue definitions (so there is no top-level
    # `queues:` key). Runtime pause/resume/scale (via Harmont.Ops.Queues →
    # base Oban) then PERSIST across restarts — important because we deploy
    # frequently: a queue paused during a Freestyle/GitHub incident must
    # survive the next deploy. The per-queue `rate_limit`s below protect
    # Freestyle (:ci) and GitHub (:gh_app) and are re-applied verbatim on every
    # boot. `sync_mode: :automatic` cleans up queues removed from this list.
    {Oban.Pro.Plugins.DynamicQueues,
     sync_mode: :automatic,
     queues: [
       ci: [local_limit: 20, rate_limit: [allowed: 30, period: 60]],
       ci_finalize: 20,
       gh_app: [local_limit: 10, rate_limit: [allowed: 80, period: 60]],
       bitbucket: [local_limit: 10, rate_limit: [allowed: 50, period: 60]],
       # local_limit raised 2->6: a 2-worker queue is trivially wedged by 2
       # stale-lease orphans (e.g. after a backend roll) while DynamicLifeline is
       # rescuing them. 6 gives headroom without exceeding the GitHub discovery
       # rate limit (allowed: 10/60s).
       discovery: [local_limit: 6, rate_limit: [allowed: 10, period: 60]],
       # Low-concurrency housekeeping (the hourly SandboxReaper). No rate limit.
       maintenance: [local_limit: 1]
     ]},
    {Oban.Pro.Plugins.DynamicLifeline, rescue_interval: :timer.minutes(2)},
    {Oban.Pro.Plugins.DynamicPruner,
     mode: {:max_age, {24, :hours}},
     queue_overrides: [
       ci: {:max_age, {1, :hour}},
       gh_app: {:max_age, {72, :hours}}
     ]},
    # DynamicCron owns ALL cron scheduling — there is no separate base
    # `Oban.Plugins.Cron` plugin. The static `crontab` here carries the fixed
    # system reapers (DeliveryReaper, SandboxReaper, AbandonedBuildReaper).
    # `sync_mode: :automatic` reaps static entries dropped from this list on
    # deploy. (Per-pipeline schedule triggers were removed; the DSL no longer
    # emits them, so there are no runtime-inserted `pipeline-<id>` entries.)
    {Oban.Pro.Plugins.DynamicCron,
     sync_mode: :automatic,
     crontab: [
       {"0 3 * * *", Harmont.GhApp.DeliveryReaper, name: "delivery-reaper"},
       {"0 * * * *", Harmont.Engine.SandboxReaper, name: "sandbox-reaper"},
       {"*/15 * * * *", Harmont.Engine.AbandonedBuildReaper, name: "abandoned-build-reaper"}
     ]}
  ]

# OTel SDK must be told to USE the exporter (the :opentelemetry_exporter block is inert alone).
#
# We register a single composite span processor — Harmont.Telemetry.QueryRedactor —
# instead of the bare `:batch` shorthand. It wraps the batch processor and scrubs secrets
# (e.g. the SSE log-stream `?token=<hmac>`) out of the `url.query` attribute before export,
# so tokens never reach the trace backend (Honeycomb in prod). The `exporter` key below is
# the batch processor's own default; for a non-builtin processor the SDK passes our config
# through verbatim, so we name the OTLP exporter explicitly here.
config :opentelemetry,
  traces_exporter: :otlp,
  processors: [
    {Harmont.Telemetry.QueryRedactor,
     %{
       scheduled_delay_ms: 5000,
       exporting_timeout_ms: 30_000,
       max_queue_size: 2048,
       exporter: {:opentelemetry_exporter, %{}}
     }}
  ]

# Configures the endpoint
config :harmont_web, HarmontWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  # Bounded in-flight connection drain on System.stop/0. ThousandIsland (under
  # Bandit) waits up to shutdown_timeout for live connections to finish before
  # forcibly closing them. Agent WebSockets can be long-lived, so we cap the
  # wait rather than block forever (:infinity) or cut instantly (0). This bounds
  # the connection-shutdown tail of the graceful drain after the LB has already
  # de-registered us via the 503 /healthz.
  http: [thousand_island_options: [shutdown_timeout: 30_000]],
  render_errors: [
    formats: [json: HarmontWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Harmont.PubSub,
  live_view: [signing_salt: "iK/NPUtK"],
  # Shared HMAC secret with harmont-api for log-channel tokens.
  # Prod overrides in runtime.exs via HARMONT_LOG_TOKEN_SECRET.
  log_token_secret: System.get_env("HARMONT_LOG_TOKEN_SECRET", "dev-log-token-secret"),
  # CORS allowlist for the SSE log stream (GET /v0/jobs/:id/logs).
  log_stream_allowed_origins: ["//localhost:8765"]

# CORS allowlist for the REST API (`/api/v0/*`), consumed by the Corsica plug in
# HarmontWeb.Endpoint via HarmontWeb.Cors. Prod default below; dev.exs points it
# at the local SPA and runtime.exs derives it from HARMONT_APP_BASE_URL.
config :harmont_web, HarmontWeb.Cors, allowed_origins: ["https://app.harmont.dev"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Swoosh (harmont_api transactional email). Use the Req-backed API client —
# `req` is already a dependency tree-wide — so Swoosh's application boots
# without pulling in Hackney (its default). The per-mailer adapter
# (Local/Test/Resend) is configured per environment (dev/test below;
# Resend in runtime.exs for prod).
config :swoosh, :api_client, Swoosh.ApiClient.Req

# harmont_api: transactional-email defaults. `app_base_url` backs the
# verification/recovery links in emails; `mail_from` is the From address.
# Per-env overrides (dev localhost, prod Resend) layer on top.
config :harmont_api, :app_base_url, "https://app.harmont.dev"
config :harmont_api, :mail_from, "no-reply@harmont.dev"

# OAuth (Assent). The per-provider keyword lists are the base Assent config —
# client credentials are env-driven in prod (runtime.exs) and use harmless
# placeholders in dev/test (the real Assent caller is bypassed in test via the
# `:oauth_impl` swap; dev never exercises the real exchange without real creds).
# `HarmontApi.OAuth.fetch_user/2` dispatches through `:oauth_impl`, defaulting to
# the real `HarmontApi.OAuth`.
config :harmont_api, :oauth,
  google: [client_id: "dev-google-client-id", client_secret: "dev-google-client-secret"],
  github: [client_id: "dev-github-client-id", client_secret: "dev-github-client-secret"]

# Stripe (billing). `stripity_stripe` reads its API key from
# `config :stripity_stripe, api_key: ...`; prod injects the real secret in
# runtime.exs from STRIPE_SECRET_KEY. The `:stripe` block carries the webhook
# signing secret and the post-checkout redirect URLs. `:stripe_impl` selects
# the behaviour implementation — the real `HarmontApi.Stripe` everywhere except
# test (which swaps in `HarmontApi.StripeFake`). Placeholders below keep dev
# booting without real Stripe creds; test.exs overrides `:stripe_impl`.
config :stripity_stripe, api_key: System.get_env("STRIPE_SECRET_KEY", "sk_test_placeholder")

config :harmont_api, :stripe,
  webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET", "whsec_placeholder"),
  checkout_success_url: "https://app.harmont.dev/billing/success",
  checkout_cancel_url: "https://app.harmont.dev/billing/cancel"

config :harmont_api, :stripe_impl, HarmontApi.Stripe

# WebAuthn relying-party config (passkeys via Wax). `rp_id` is the registrable
# domain the passkey is scoped to; `origin` is the exact SPA origin Wax checks
# against the client data. Defaults target prod; dev/runtime override below.
config :harmont_api, :webauthn, rp_id: "harmont.dev", origin: "https://app.harmont.dev"

# Webhook provider registry for the generic `/webhooks/:provider` plug
# (Harmont.Apps.Webhook + ProcessDelivery -> Harmont.Apps.Engine). GitHub is the
# only provider with a static fallback here; each provider's Application
# re-registers itself at boot so the wiring survives a config override, and these
# static fallbacks keep the plug functional even before the provider subtree
# starts. Dispatch goes through the single `Harmont.Apps.Engine.handle/3` target
# (resolved per `:providers`), so there is no per-provider `:handlers` map.
config :harmont_apps, :providers, github: Harmont.GhApp.Provider
config :harmont_apps, :secrets, github: {Harmont.GhApp.Runtime, :webhook_secret}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
