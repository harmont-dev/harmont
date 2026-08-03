import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :harmont_core, Harmont.Repo,
  username: System.get_env("PGUSER", "harmont"),
  password: System.get_env("PGPASSWORD", "harmont"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "harmont_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :harmont_core, Oban, testing: :manual

# Oban Web dashboard (Task 11) HTTP Basic creds. Prod sources these from
# HARMONT_OBAN_DASHBOARD_USER / _PASSWORD via runtime.exs; the suite pins fixed
# values so the auth plug's 401/200 branches are deterministic.
config :harmont_web, :oban_dashboard, user: "admin", password: "secret"

# Oban.Met (the metrics aggregator the Oban Web dashboard reads from) only
# auto-starts when Oban's `testing` mode is in `:auto_testing_modes` — which
# defaults to `[:disabled]`. Our Oban runs `testing: :manual`, so add `:manual`
# here; otherwise the dashboard render (oban_dashboard_test) raises
# "no config registered for [Oban, Oban.Met]". This only starts the in-memory
# aggregator process; it inserts/runs nothing.
config :oban_met, auto_testing_modes: [:disabled, :manual]

# Oban Pro encrypted-args key (Task 8): a FIXED 32-byte, Base64-encoded test key
# so encrypted-worker inserts/decrypts are deterministic across the suite. The
# MFA `{Application, :fetch_env!, [:harmont_core, :oban_encryption_key]}` returns
# this string verbatim (Pro expects the Base64 string, not the decoded bytes).
config :harmont_core, :oban_encryption_key, "fc9fw9Im89JAMN21aXs2ZQ1/8u+mz9LFm56oYOXS/eg="

# Fixed dev/test Cloak key — 32 bytes, Base64. Prod uses HARMONT_CLOAK_KEY (runtime.exs).
config :harmont_core, Harmont.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("fc9fw9Im89JAMN21aXs2ZQ1/8u+mz9LFm56oYOXS/eg="),
       iv_length: 12}
  ]

# Source/artifact storage in tests: filesystem-backed Local adapter under a
# dedicated tmp dir so the suite never touches GCP and leaves no global state.
config :harmont, :storage, Harmont.Storage.Local
config :harmont, Harmont.Storage.Local, root: Path.join(System.tmp_dir!(), "harmont-storage-test")
config :harmont_engine, :use_agent, false
# Never arm the SIGTERM/graceful-drain handler in the test VM — the suite would
# otherwise risk swapping in a handler that can call System.stop/0.
config :harmont_core, :graceful_shutdown, false
# Neutralize drain in tests: grace=0 so the spawned process fires immediately
# (no 20s timer lingering after the test), and a no-op stop_fun so no test
# path can reach the real System.stop/0.
config :harmont_core, :drain_grace_ms, 0
config :harmont_core, :drain_stop_fun, fn -> :ok end
config :harmont_vm, :backend, HarmontVm.Backend.Local

config :harmont_vm, HarmontVm.Backend.Freestyle,
  api_key: "test-key",
  req_options: [plug: {Req.Test, FreestyleStub}]

# The Runloop backend reads its client config from this package's own app env.
# In tests, inject a Req.Test plug so no network is hit, and disable Req's
# transient retry so error-path tests are fast and deterministic.
config :harmont_vm, HarmontVm.Backend.Runloop,
  api_key: "test-key",
  req_options: [plug: {Req.Test, RunloopStub}, retry: false]

config :harmont_vm, HarmontVm.Backend.Daytona,
  api_key: "test-key",
  snapshot: "test-runner-snapshot",
  req_options: [plug: {Req.Test, DaytonaStub}, retry: false]

# Keep the snapshot-status poll loop fast in tests (prod default is 2s).
config :harmont_vm, snapshot_poll_interval_ms: 5
# Keep the fork-retry backoff tiny in tests (prod default is 500ms).
config :harmont_vm, fork_retry_interval_ms: 1
# Keep the live-VM fork-tree reap passes tight in tests (prod default is 2s).
config :harmont_vm, reap_pass_interval_ms: 1

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :harmont_web, HarmontWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ddCRefWCYDBYP0KG4YBCzShYqGMOFSB7u5nN+hVMtBr/xn458Ij4e/BqI3Pc7lzP",
  server: false

# Disable OTel export in test — spans are no-ops unless a test sets up its own processor.
# config.exs registers the QueryRedactor composite processor with the OTLP exporter; here we
# override `processors` so the wrapped batch processor exports nowhere (no network in tests).
# The QueryRedactor unit tests exercise the redaction logic directly, not through this pipeline.
config :opentelemetry,
  traces_exporter: :none,
  processors: [
    {Harmont.Telemetry.QueryRedactor,
     %{
       scheduled_delay_ms: 5000,
       exporting_timeout_ms: 30_000,
       max_queue_size: 2048,
       exporter: :none
     }}
  ]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# No real HTTP from Swoosh in tests — the API client is never invoked because
# the test mailer adapter captures messages in-process.
config :swoosh, :api_client, false

# Mailer: collect emails in the Swoosh test mailbox so tests can assert on them
# without delivering anything.
config :harmont_api, HarmontApi.Mailer, adapter: Swoosh.Adapters.Test

# OAuth: swap the real Assent caller for the in-process fake so the auth-endpoint
# tests can drive the allowed/denied/provider-error branches off canned data
# keyed by the `code` param, with no real HTTP.
config :harmont_api, :oauth_impl, HarmontApi.OAuthFake

# WebAuthn: swap the real Wax verification boundary for an in-process fake so
# the passkey signup/login orchestration can be driven end-to-end (challenge
# store/consume, user creation, sign-counter, session minting are all real) off
# canned attestation/assertion results — no real signing authenticator needed.
# The crypto itself is covered by Wax's own FIDO2 conformance suite.
config :harmont_api, :webauthn_impl, HarmontApi.WebauthnFake

# Stripe: swap the real stripity_stripe boundary for the in-process fake so the
# billing tests drive checkout/webhook off canned data with no real Stripe
# network or signing. The webhook secret is a fixed placeholder (the fake never
# checks it); a fixed redirect base keeps assertions deterministic.
config :harmont_api, :stripe_impl, HarmontApi.StripeFake

config :harmont_api, :stripe,
  webhook_secret: "whsec_test",
  checkout_success_url: "https://app.test/billing/success",
  checkout_cancel_url: "https://app.test/billing/cancel"

# OpenApiSpex: don't cache the built spec across processes in test. The default
# (persistent_term) cache is keyed by the spec module, so when both harmont_api's
# ping test and harmont_web's API-mount test render HarmontApi.ApiSpec in one
# umbrella `mix test` run, the first render's cached value is reused by the
# second — and the round-trip drops fields (e.g. info.version reads back nil).
# Rebuilding per render keeps cross-app spec assertions correct.
config :open_api_spex, :cache_adapter, OpenApiSpex.Plug.NoneCache
