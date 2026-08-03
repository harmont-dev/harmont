defmodule Harmont.Apps.Provider do
  @moduledoc """
  The ONLY provider-specific surface in the multi-provider VCS layer. Every
  third-party application provider (GitHub, Bitbucket, …) implements this
  behaviour, and `Harmont.Apps.Engine` drives the entire build/fan-out,
  delivery, fork-resolution, lifecycle, and reporting pipeline through these
  callbacks — never by branching on the provider itself.

  ## Capability-driven dispatch

  `capabilities/0` returns ONE static map the engine reads to decide behavior
  (fork fetch strategy, cross-namespace policy, trust policy, whether a distinct
  check object must be created, whether the provider emits lifecycle events,
  rerun support, and the Oban queue for this provider's delivery/status work).
  The engine branches on these capability fields; it must NEVER `case provider`.
  A new provider inherits the whole policy surface by declaring capability keys,
  and overrides only the fields that genuinely differ.

  ## Opaque-client threading

  `fetch_token/1` returns an **opaque provider client** (e.g. a
  `%GithubClient{}` or `%BitbucketClient{}`), not a bare string. The engine
  acquires this client ONCE per delivery and threads it, untouched, into every
  network seam (`download_tarball/4`, `create_check/3`, `report/3`,
  `apply_lifecycle/2`). Providers are the only code that interprets the client.

  ## Vocabulary translation lives in the provider

  Reporting callbacks receive the provider-neutral `Harmont.Apps.BuildState`.
  Providers project that neutral state to their own wire vocabulary (GitHub
  Check Run status/conclusion, Bitbucket Build Status / Code Insights) inside
  their own `report/3`. The neutral→wire mapping must not leak into the engine,
  and the agg→neutral mapping (in `Harmont.Apps.BuildState`) must not re-acquire
  vendor literals.

  ## `__using__`

  `use Harmont.Apps.Provider` declares `@behaviour Harmont.Apps.Provider` and
  supplies overridable defaults for `capabilities/0` (the conservative default
  map), `apply_lifecycle/2` (`:ok` — for providers without lifecycle events),
  and `clone_url/2`. A provider overrides only the genuinely-specific seams.

  Implementations are stateless modules; per-provider config (secrets, base
  URLs) is resolved by the implementation itself. They are looked up by `id/0`
  through `Harmont.Apps.Registry`.
  """

  alias Harmont.Apps.BuildState
  alias Harmont.Apps.Event

  @typedoc "Header name/value pairs from the inbound webhook request, lower-cased keys."
  @type headers :: [{String.t(), String.t()}]

  @typedoc "A `vcs_provider_check` row (the build↔external-check link)."
  @type check :: map()

  @typedoc """
  An OPAQUE provider client returned by `fetch_token/1` and threaded by the
  engine into every network seam. Only the owning provider interprets it.
  """
  @type client :: term()

  @typedoc """
  The static capability map the engine reads to drive provider-agnostic
  behavior. See `c:capabilities/0` for the field semantics.
  """
  @type capabilities :: %{
          fork_fetch: :base_repo_at_head_sha | :head_repo_only,
          fork_cross_namespace: :buildable | :unbuildable,
          trust_policy: :build_forks | :skip_forks,
          distinct_check_create: boolean(),
          lifecycle_events: boolean(),
          rerun: boolean(),
          queue: atom()
        }

  @doc "Stable provider id, e.g. :github. Matches the `:provider` URL segment and the DB `provider` column."
  @callback id() :: atom()

  @doc "Request header carrying the event type (GitHub: x-github-event)."
  @callback event_header() :: String.t()

  @doc "Request header carrying the dedup delivery id (GitHub: x-github-delivery)."
  @callback delivery_header() :: String.t()

  @doc """
  The static capability map the engine branches on. Fields:

    * `:fork_fetch` — `:base_repo_at_head_sha` (the base repo's tarball serves
      the fork head SHA, e.g. GitHub) or `:head_repo_only` (must fetch from the
      head fork repo, e.g. Bitbucket).
    * `:fork_cross_namespace` — `:buildable` or `:unbuildable`: whether a fork
      PR whose head lives in a namespace other than the install namespace can be
      built.
    * `:trust_policy` — `:build_forks` (default) or `:skip_forks` (ack 200 with
      no build for fork PRs).
    * `:token` — `:mint` (ephemeral JIT) or `:persisted_rotate` (stored OAuth);
      informational.
    * `:distinct_check_create` — whether the engine must call `create_check/3`
      (GitHub creates a Check Run; Bitbucket's first status IS the check).
    * `:lifecycle_events` — whether the provider emits install/repo lifecycle
      events that the engine routes to `apply_lifecycle/2`.
    * `:rerun` — whether the provider supports check-rerun dispatch.
    * `:queue` — the Oban queue for this provider's delivery + status work.

  `use Harmont.Apps.Provider` supplies a conservative default; providers merge
  their overrides over it.
  """
  @callback capabilities() :: capabilities()

  @doc """
  Verify the webhook signature over the **raw** request bytes. `headers` carries
  the full lower-cased header list so providers can read whichever signature
  header they use. Returns false on any mismatch or missing signature.
  """
  @callback verify_signature(secret :: String.t(), raw_body :: binary(), headers()) :: boolean()

  @doc """
  Decode a raw webhook into normalized events. Decode is TOTAL over the full
  event set: push, pull-request, lifecycle, and rerun.

    * `{:ok, [Event.t()]}` — one or more normalized events to process. Lifecycle
      events (`:installation_added`/`:installation_removed`/
      `:installation_suspended`/`:installation_unsuspended`/`:repos_changed`)
      and `:rerun` events MUST be emitted here when the provider supports them.
      A `:rerun` for a check_run carries `pr: %{rerun_pin: :stored_coords}`
      (anti-spoof: the engine reuses persisted coords); a `:rerun` from a
      check_suite carries `pr: %{rerun_pin: :payload_coords}`.
    * `{:ok, :ack}` — valid but nothing to do (e.g. GitHub ping).
    * `{:error, :unsupported}` — an event type we ignore.
  """
  @callback decode(event_name :: String.t(), json :: map()) ::
              {:ok, [Event.t()] | :ack} | {:error, term()}

  @doc """
  Acquire a usable, OPAQUE provider client for the given installation external
  id. The engine acquires this once per delivery and threads it into every
  network seam (`download_tarball/4`, `create_check/3`, `report/3`,
  `apply_lifecycle/2`).
  """
  @callback fetch_token(installation_external_id :: String.t()) ::
              {:ok, client()} | {:error, term()}

  @doc """
  Download the source tarball for already-fork-resolved coordinates. This is the
  ONLY place a provider's download client is called; the engine has already
  resolved `owner`/`repo`/`ref` via fork policy. Errors distinguish transient
  rate limiting (with a retry-after seconds hint) from permanent vs transient
  archive failures.
  """
  @callback download_tarball(
              client(),
              owner :: String.t(),
              repo :: String.t(),
              ref :: String.t()
            ) ::
              {:ok, binary()}
              | {:error, {:rate_limited, non_neg_integer()}}
              | {:error, {:archive_permanent | :archive_transient, term()}}

  @doc """
  Deterministic fallback clone URL for the given repo, used when no `vcs_repo`
  mirror row exists. `use Harmont.Apps.Provider` supplies an overridable
  default.
  """
  @callback clone_url(owner :: String.t(), repo :: String.t()) :: String.t()

  @doc """
  Create the external check object for a freshly-created build and return its
  provider check id (string). Only invoked when
  `capabilities().distinct_check_create == true`. `ctx` carries
  owner/repo/head_sha/branch/details_url/installation_external_id; `client` is
  the opaque provider client from `fetch_token/1`.
  """
  @callback create_check(build :: map(), ctx :: map(), client()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Push a build-state transition to the provider for an existing
  `vcs_provider_check` row. Receives the NEUTRAL `Harmont.Apps.BuildState`; the
  provider projects it to its own wire vocabulary internally. The engine owns
  the terminal `Vcs.mark_provider_check_state` write — providers must not call
  it.
  """
  @callback report(check(), BuildState.t(), client()) ::
              :ok | {:error, {:rate_limited, non_neg_integer()} | term()}

  @doc """
  Apply a normalized lifecycle event (install added/removed/suspended/
  unsuspended, repos changed). The engine routes lifecycle Events here.
  `client` may be `nil` for events that don't need an API call. GitHub
  upserts/tombstones the `vcs_installation`, enqueues repo sync, rediscovery,
  and open-mapping teardown. `use Harmont.Apps.Provider` supplies an overridable
  default that returns `:ok` (for providers without lifecycle events).
  """
  @callback apply_lifecycle(Event.t(), client() | nil) :: :ok | {:error, term()}

  @doc """
  Vendor-specific metadata to persist on the `vcs_provider_check.provider_data`
  jsonb sidecar at check-creation time, so the canonical neutral columns never
  re-acquire vendor vocabulary AND the provider's `report/3` can read a stable id
  rather than recomputing it. `summary` carries the build's external id /
  pipeline slug; `ctx` carries owner/repo/head_sha/branch. Returns a JSON-able
  map (e.g. `%{"code_insights_report_id" => "..."}`). `use Harmont.Apps.Provider`
  supplies an overridable default of `%{}` (no sidecar metadata).
  """
  @callback initial_provider_data(summary :: map(), ctx :: map()) :: map()

  @doc """
  Whether the provider's installation external ids are numeric (e.g. GitHub
  installation integers) vs opaque slugs/paths (e.g. Bitbucket workspace slugs).
  The engine uses this — NOT provider identity, and NOT an unrelated fork
  capability — to validate a stored-coords rerun's install id. `use
  Harmont.Apps.Provider` supplies an overridable default of `:opaque`.
  """
  @callback install_id_format() :: :numeric | :opaque

  @doc """
  Best-effort enqueue of pipeline rediscovery for a repo whose default branch was
  just pushed (a `.hm/*.py` edit must refresh stored pipelines/triggers). The
  engine calls this after a successful default-branch push fan-out, having already
  confirmed `event.branch == default_branch` via the mirrored `vcs_repo` row, so
  the provider only enqueues its durable discovery worker. MUST be idempotent /
  Oban-deduped and never raise (a webhook ack must not be blocked). `use
  Harmont.Apps.Provider` supplies an overridable default of `:ok` (no-op).
  """
  @callback rediscover(installation_external_id :: String.t(), repo_full_name :: String.t()) :: :ok

  @doc """
  The conservative default capability map. A provider's declared keys are merged
  over this by `use Harmont.Apps.Provider`.
  """
  @spec default_capabilities() :: capabilities()
  def default_capabilities do
    %{
      fork_fetch: :head_repo_only,
      fork_cross_namespace: :unbuildable,
      trust_policy: :build_forks,
      distinct_check_create: true,
      lifecycle_events: false,
      rerun: false,
      queue: :gh_app
    }
  end

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Harmont.Apps.Provider

      @__provider_capability_overrides Map.new(opts)

      @impl Harmont.Apps.Provider
      def capabilities do
        # Fully-qualified on purpose: this body is injected into each provider
        # module by __using__, where an alias would not resolve. credo:disable.
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        Map.merge(Harmont.Apps.Provider.default_capabilities(), @__provider_capability_overrides)
      end

      @impl Harmont.Apps.Provider
      def apply_lifecycle(_event, _client), do: :ok

      @impl Harmont.Apps.Provider
      def clone_url(owner, repo), do: "https://example.invalid/#{owner}/#{repo}.git"

      @impl Harmont.Apps.Provider
      def initial_provider_data(_summary, _ctx), do: %{}

      @impl Harmont.Apps.Provider
      def install_id_format, do: :opaque

      @impl Harmont.Apps.Provider
      def rediscover(_installation_external_id, _repo_full_name), do: :ok

      defoverridable capabilities: 0,
                     apply_lifecycle: 2,
                     clone_url: 2,
                     initial_provider_data: 2,
                     install_id_format: 0,
                     rediscover: 2
    end
  end
end
