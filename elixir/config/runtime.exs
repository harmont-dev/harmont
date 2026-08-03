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
#     PHX_SERVER=true bin/hmex start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :harmont_web, HarmontWeb.Endpoint, server: true
end

if config_env() == :prod do
  config :opentelemetry, :resource, service: %{name: "harmont"}

  # The GitHub-App subtree is required in prod: if the HARMONT_GITHUB_* env
  # vars (read by Harmont.GhApp.Settings.load/1 at boot) are missing
  # or invalid, refuse to boot rather than silently dropping webhooks. Dev/test
  # leave this unset (false), so missing secrets just skip the gh-app subtree.
  config :harmont_gh_app, :gh_app_required, true

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://api.honeycomb.io"),
    otlp_headers: [{"x-honeycomb-team", System.fetch_env!("HONEYCOMB_API_KEY")}]

  # Source/artifact blob storage in prod: Google Cloud Storage. The GCS client
  # wiring (Goth + signed URLs) is Plan-8 infra; this selects the adapter and
  # names its bucket. Dev/test stay on Harmont.Storage.Local (config.exs).
  if bucket = System.get_env("HARMONT_SOURCE_BUCKET") do
    config :harmont, :storage, Harmont.Storage.Gcs
    config :harmont, Harmont.Storage.Gcs, bucket: bucket
  end

  # Public base URL the in-VM job agent dials for its control WebSocket
  # (`<url>/v0/agent/connect`, http→ws / https→wss in the agent). Same host as
  # the source endpoint; defaults to localhost for dev, so prod MUST set it or
  # the agent never connects and every job times out.
  config :harmont_engine,
         :agent_ws_url,
         System.get_env("HARMONT_API_URL", "https://api.harmont.dev")

  # Enqueue a one-off SandboxReaper sweep at boot so a freshly-rolled MIG
  # instance clears accumulated leaked/broken sandboxes right away rather than
  # waiting up to an hour for the hourly cron tick. Off by default (dev/test).
  config :harmont_engine, :reap_on_boot, true

  # Absolute base for the internal source-archive endpoint the webhook-driven
  # build path stamps onto each build's `source_url` (the render sandbox + job
  # agent fetch it from a remote VM, so it can't be relative). Same host as the
  # agent WebSocket above.
  config :harmont_apps,
         :api_base_url,
         System.get_env("HARMONT_API_URL", "https://api.harmont.dev")

  # Oban Pro encrypted-args key (Task 8): the runner token is stored encrypted in
  # `oban_jobs.args`. The env var holds a 32-byte, Base64-encoded string (generate
  # with `32 |> :crypto.strong_rand_bytes() |> Base.encode64()`); the MFA returns
  # it verbatim to Pro. Required at boot — refuse to start without it so the token
  # is never silently persisted in plaintext.
  config :harmont_core,
         :oban_encryption_key,
         System.fetch_env!("HARMONT_OBAN_ENCRYPTION_KEY")

  # Cloak field-level encryption key (AES-256-GCM). Holds a 32-byte, Base64-encoded
  # string (generate with `32 |> :crypto.strong_rand_bytes() |> Base.encode64()`).
  # Required at boot — refuse to start without it so credential fields are never
  # silently persisted in plaintext.
  config :harmont_core, Harmont.Vault,
    ciphers: [
      default:
        {Cloak.Ciphers.AES.GCM,
         tag: "AES.GCM.V1",
         key: Base.decode64!(System.fetch_env!("HARMONT_CLOAK_KEY")),
         iv_length: 12}
    ]

  # Oban Web dashboard (Task 11) HTTP Basic creds. The dashboard at /ops/oban
  # exposes job args/meta + cancel/retry, so it is gated by
  # HarmontWeb.Plugs.ObanDashboardAuth. Both vars are required at boot in prod —
  # refuse to start with a half-configured (or worse, world-readable) ops
  # surface rather than failing the gate at request time.
  config :harmont_web, :oban_dashboard,
    user: System.fetch_env!("HARMONT_OBAN_DASHBOARD_USER"),
    password: System.fetch_env!("HARMONT_OBAN_DASHBOARD_PASSWORD")

  # Select the VM backend at boot. Runloop is the core provider (Freestyle's
  # 500s pushed us off it); set HARMONT_VM_BACKEND=freestyle to roll back, or
  # HARMONT_VM_BACKEND=daytona for the fast copy-on-write fork provider (used for
  # `builds_in` lineage — cutover is a later phase, default stays runloop).
  # NOTE: the default now requires RUNLOOP_API_KEY in the environment — boot
  # crashes without it (fetch_env! below).
  vm_backend =
    case System.get_env("HARMONT_VM_BACKEND", "runloop") do
      "freestyle" ->
        HarmontVm.Backend.Freestyle

      "runloop" ->
        HarmontVm.Backend.Runloop

      "daytona" ->
        HarmontVm.Backend.Daytona

      other ->
        raise """
        HARMONT_VM_BACKEND must be "freestyle", "runloop", or "daytona", got: #{inspect(other)}.
        Unset it to use the Runloop default.
        """
    end

  config :harmont_vm, :backend, vm_backend

  case vm_backend do
    HarmontVm.Backend.Freestyle ->
      config :harmont_vm, HarmontVm.Backend.Freestyle,
        api_key: System.fetch_env!("FREESTYLE_API_KEY")

    HarmontVm.Backend.Runloop ->
      config :harmont_vm, HarmontVm.Backend.Runloop,
        api_key: System.fetch_env!("RUNLOOP_API_KEY"),
        blueprint_id: System.get_env("RUNLOOP_BLUEPRINT_ID")

    HarmontVm.Backend.Daytona ->
      config :harmont_vm, HarmontVm.Backend.Daytona,
        api_key: System.fetch_env!("DAYTONA_API_KEY"),
        snapshot: System.fetch_env!("DAYTONA_SNAPSHOT")
  end

  # :ci queue global rate limit (Oban Pro Smart engine). The compile-time
  # default lives in config/config.exs; here we make the Freestyle-provision
  # throttle tunable per deploy without dropping the other queues. `period` is
  # in seconds.
  ci_allowed = String.to_integer(System.get_env("HARMONT_CI_RATE_ALLOWED", "30"))
  ci_period = String.to_integer(System.get_env("HARMONT_CI_RATE_PERIOD", "60"))

  # :gh_app queue global rate limit. All GitHub-API-calling work (CheckRunUpdate,
  # ProcessDelivery, SyncRepos) runs on :gh_app, so a single global cap here bounds
  # the aggregate GitHub request rate across the cluster — the thing that trips
  # GitHub's secondary rate limit (429/403) under fan-out.
  gh_allowed = String.to_integer(System.get_env("HARMONT_GH_RATE_ALLOWED", "80"))
  gh_period = String.to_integer(System.get_env("HARMONT_GH_RATE_PERIOD", "60"))

  # :bitbucket queue global rate limit. All Bitbucket-API-calling delivery work
  # runs on :bitbucket, so a single global cap here bounds the aggregate
  # Bitbucket request rate across the cluster (mirrors :gh_app for GitHub).
  bb_allowed = String.to_integer(System.get_env("HARMONT_BITBUCKET_RATE_ALLOWED", "50"))
  bb_period = String.to_integer(System.get_env("HARMONT_BITBUCKET_RATE_PERIOD", "60"))

  oban_cfg = Application.fetch_env!(:harmont_core, Oban)

  # DynamicQueues now OWNS the queue list, so there is no top-level `:queues`
  # key to override. Instead we reach into the DynamicQueues plugin tuple inside
  # `:plugins`, MERGE the env-driven rate limits over its `:queues` opt (so
  # `:ci_finalize`, the `local_limit`s, and every other plugin are preserved
  # verbatim), and put the plugins list back — one coherent Oban config block.
  plugins = Keyword.fetch!(oban_cfg, :plugins)

  {dq_opts, dq_index} =
    plugins
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{Oban.Pro.Plugins.DynamicQueues, opts}, index} -> {opts, index}
      _ -> false
    end) ||
      raise "expected an Oban.Pro.Plugins.DynamicQueues plugin in :harmont_core Oban config"

  dq_queues = Keyword.fetch!(dq_opts, :queues)

  ci_opts =
    dq_queues
    |> Keyword.fetch!(:ci)
    |> Keyword.put(:rate_limit, allowed: ci_allowed, period: ci_period)

  gh_opts =
    dq_queues
    |> Keyword.fetch!(:gh_app)
    |> Keyword.put(:rate_limit, allowed: gh_allowed, period: gh_period)

  bb_opts =
    dq_queues
    |> Keyword.fetch!(:bitbucket)
    |> Keyword.put(:rate_limit, allowed: bb_allowed, period: bb_period)

  dq_queues =
    dq_queues
    |> Keyword.put(:ci, ci_opts)
    |> Keyword.put(:gh_app, gh_opts)
    |> Keyword.put(:bitbucket, bb_opts)

  dq_plugin = {Oban.Pro.Plugins.DynamicQueues, Keyword.put(dq_opts, :queues, dq_queues)}
  plugins = List.replace_at(plugins, dq_index, dq_plugin)

  config :harmont_core, Oban, Keyword.put(oban_cfg, :plugins, plugins)

  # Mailer: deliver via Resend in production. RESEND_API_KEY is required at boot.
  config :harmont_api, HarmontApi.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: System.fetch_env!("RESEND_API_KEY")

  # OAuth (Assent). Client credentials are required at boot in prod — refuse to
  # start with a half-configured auth edge rather than failing sign-in at runtime.
  config :harmont_api, :oauth,
    google: [
      client_id: System.fetch_env!("GOOGLE_OAUTH_CLIENT_ID"),
      client_secret: System.fetch_env!("GOOGLE_OAUTH_CLIENT_SECRET")
    ],
    github: [
      client_id: System.fetch_env!("GITHUB_OAUTH_CLIENT_ID"),
      client_secret: System.fetch_env!("GITHUB_OAUTH_CLIENT_SECRET")
    ]

  # WebAuthn relying-party: passkeys are scoped to harmont.dev; the origin Wax
  # checks against is the SPA at app.harmont.dev. Overridable via env in case the
  # SPA origin moves.
  config :harmont_api, :webauthn,
    rp_id: System.get_env("HARMONT_WEBAUTHN_RP_ID", "harmont.dev"),
    origin: System.get_env("HARMONT_WEBAUTHN_ORIGIN", "https://app.harmont.dev")

  # Stripe (billing). OPTIONAL in prod: when the API key + webhook signing
  # secret are absent, the app still boots and the billing edge reports itself
  # unconfigured (checkout → 503 `billing_unconfigured`, webhook → 400) rather
  # than crash-looping at boot. Set both env vars to turn billing on. The
  # redirect URLs derive from the SPA host.
  config :stripity_stripe, api_key: System.get_env("STRIPE_SECRET_KEY")

  app_base = System.get_env("HARMONT_APP_BASE_URL", "https://app.harmont.dev")

  config :harmont_api, :stripe,
    webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
    checkout_success_url:
      System.get_env("STRIPE_CHECKOUT_SUCCESS_URL", "#{app_base}/billing/success"),
    checkout_cancel_url:
      System.get_env("STRIPE_CHECKOUT_CANCEL_URL", "#{app_base}/billing/cancel")

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :harmont_core, Harmont.Repo,
    url: System.fetch_env!("HARMONT_DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "20")),
    # The list form of :ssl both enables TLS and carries the options; the old
    # `ssl: true` + `ssl_opts:` pair is deprecated (db_connection logs a warning
    # per pooled connection). verify_none stays — Cloud SQL is reached over a
    # private VPC IP with no server cert to pin.
    ssl: [verify: :verify_none],
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

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :harmont_web, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :harmont_web, HarmontWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    log_token_secret: System.fetch_env!("HARMONT_LOG_TOKEN_SECRET"),
    log_stream_allowed_origins: ["https://app.harmont.dev:443"]

  # CORS allowlist for the REST API. The browser sends `Origin:
  # https://app.harmont.dev` (no :443), so match that exact string. Tracks
  # HARMONT_APP_BASE_URL so it moves with the SPA host without a code change.
  config :harmont_web, HarmontWeb.Cors, allowed_origins: [app_base]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :harmont_web, HarmontWeb.Endpoint,
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
  #     config :harmont_web, HarmontWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
