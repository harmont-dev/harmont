# Script for populating the local dev database with a usable fixture:
# a dev user + personal org, a `default` org the user admins, a fixed dev API
# bearer token, a sample pipeline, and a few builds/jobs/log lines.
#
# Run it with:
#
#     mix run apps/harmont_core/priv/repo/seeds.exs
#
# It is idempotent — every insert is guarded by a get-or-create / existence
# check / on_conflict, so re-running converges to the same state without
# duplicating rows or raising on conflicts.
#
# Seed logic lives here (in Elixir, against the real schema + contexts) rather
# than in raw SQL so it cannot drift from the Ecto schema. We prefer the domain
# contexts (Accounts/Orgs/Pipelines/Builds) over `Repo.insert` so invariants
# (slugs, build numbers, personal-org wiring, token hashing) hold; we fall back
# to changesets only where no context function fits (job logs have no context
# module yet — they are written at runtime by the executor's
# `Harmont.Logs.Store`).

alias Harmont.Accounts
alias Harmont.Accounts.ApiToken
alias Harmont.Builds
alias Harmont.Logs.LogChunk
alias Harmont.Orgs
alias Harmont.Orgs.Organization
alias Harmont.Pipelines
alias Harmont.Repo
alias Harmont.Token

dev_email = "dev@harmont.local"
dev_name = "Dev User"
org_slug = "default"
org_name = "Default Org"
pipeline_slug = "demo"

# Stable, local-only dev bearer. This is NOT a secret — it only grants access to
# a localhost dev database. Keeping it fixed makes the seed idempotent and keeps
# scripts/dev-seed.sh's .hm-dev-env valid across re-runs.
dev_token = "hmt_localdev_devseed"

# --- Dev user (+ personal org), via the OAuth/identity upsert path -----------
# `find_or_create_user_from_identity/3` is the canonical "get-or-create user"
# entry point: on first run it inserts the user, a personal org, and an admin
# membership in one transaction; on later runs it finds the existing user by
# email and returns `created? == false`. We use the `:passkey` provider so no
# provider_id is required.
{:ok, user, _created?} =
  Accounts.find_or_create_user_from_identity(%{
    provider: :passkey,
    email: dev_email,
    name: dev_name
  })

# --- Default org + admin membership ------------------------------------------
# get-or-create on the unique slug; then ensure the dev user is an admin member.
org =
  case Repo.get_by(Organization, slug: org_slug) do
    %Organization{} = existing ->
      existing

    nil ->
      {:ok, created} = Orgs.create_org(%{name: org_name, slug: org_slug}, Repo)
      created
  end

# `add_member/4` raises on the unique (organization_id, user_id) index on a
# re-run, so guard it with the context's own membership check.
case Orgs.require_member(user, org, Repo) do
  :ok -> :ok
  {:error, :not_found} -> {:ok, _} = Orgs.add_member(org, user, :admin, Repo)
end

# --- Fixed dev API bearer token ----------------------------------------------
# Token-convergent auth: the bearer is the SHA-256 hash (Token.hash/1) of the
# raw value, stored in `api_tokens`. We insert the hash directly via the
# ApiToken changeset — Accounts.create_session_token/3 mints a *random* token
# with a 30-day expiry, but we need a *fixed*, non-expiring dev bearer.
# on_conflict: :nothing on the unique token_hash keeps it idempotent.
{:ok, _token} =
  %ApiToken{}
  |> ApiToken.changeset(%{
    description: "dev-seed local token",
    token_hash: Token.hash(dev_token),
    token_type: :personal,
    user_id: user.id
  })
  |> Repo.insert(on_conflict: :nothing, conflict_target: :token_hash)

# --- Sample pipeline ----------------------------------------------------------
pipeline =
  case Pipelines.fetch_pipeline(org, pipeline_slug, Repo) do
    {:ok, existing} ->
      existing

    {:error, :not_found} ->
      {:ok, created} =
        Pipelines.create_pipeline(
          org,
          %{
            name: "Demo Pipeline",
            slug: pipeline_slug,
            description: "Sample pipeline for local development",
            repository: "https://github.com/example/demo",
            default_branch: "main"
          },
          Repo
        )

      created
  end

# --- Builds + jobs + logs -----------------------------------------------------
# Three builds — one passed, one failed, one running — each with three jobs
# (setup → build → test) whose states roll up to the build's. Build/job `state`
# columns are plain strings validated by `validate_inclusion/3`; we use the
# wire values directly (build: passed/failed/running, job:
# passed/failed/running). `create_build/3` allocates the per-pipeline build
# number inside a transaction; we override the executor-default `state` and set
# the timestamps via the same changeset.
now = DateTime.utc_now()

# Each spec: build state + the three jobs' states + the test job's exit code.
build_specs = [
  %{state: "passed", job_states: ~w(passed passed passed), test_exit: 0},
  %{state: "failed", job_states: ~w(passed passed failed), test_exit: 1},
  %{state: "running", job_states: ~w(passed passed running), test_exit: nil}
]

job_names = ~w(setup build test)
job_commands = ["echo setup", "echo build && make", "echo test && make test"]

# Idempotency: a build is identified by (pipeline_id, number). Because we don't
# control `number` (the context allocates it), we instead key off the commit —
# if a build with this seed's commit already exists for the pipeline, skip it.
# That keeps re-runs from stacking up new builds on every invocation.
existing_commits =
  Builds.list_for_pipeline(pipeline, Repo)
  |> MapSet.new(& &1.commit)

build_specs
|> Enum.with_index(1)
|> Enum.each(fn {spec, idx} ->
  commit = "seedc0mmit#{idx}"

  unless MapSet.member?(existing_commits, commit) do
    started_at = DateTime.add(now, -(4 - idx) * 3600, :second)

    finished_at =
      if spec.state == "running", do: nil, else: DateTime.add(started_at, 180, :second)

    {:ok, build} =
      Builds.create_build(
        pipeline,
        %{
          state: spec.state,
          source: "ui",
          branch: "main",
          commit: commit,
          message: "Build ##{idx} — sample #{spec.state} commit",
          author: dev_name,
          scheduled_at: started_at,
          started_at: started_at,
          finished_at: finished_at
        },
        Repo
      )

    [job_names, job_commands, spec.job_states]
    |> Enum.zip()
    |> Enum.each(fn {name, command, job_state} ->
      job_finished_at = if job_state == "running", do: nil, else: finished_at
      exit_code = if name == "test", do: spec.test_exit, else: 0

      {:ok, job} =
        %Harmont.Builds.Job{}
        |> Harmont.Builds.Job.changeset(%{
          build_id: build.id,
          step_key: name,
          name: name,
          job_type: "script",
          command: command,
          state: job_state,
          exit_code: exit_code,
          soft_failed: false,
          started_at: started_at,
          finished_at: job_finished_at
        })
        |> Repo.insert()

      # One log chunk per job so the log viewer renders content. No logs context
      # module exists yet (the executor writes via Harmont.Logs.Store at
      # runtime), so we insert the LogChunk row directly through its changeset.
      # `content` is a :binary column; a UTF-8 string is valid. seq 0 is the
      # first chunk; the unique (job_id, seq) index makes this idempotent if the
      # build somehow survived but the chunk did not.
      {:ok, _chunk} =
        %LogChunk{}
        |> LogChunk.changeset(%{
          job_id: job.id,
          seq: 0,
          stream_kind: 0,
          content: "$ #{command}\n#{name} step complete.\n",
          ts_unix_ns: System.os_time(:nanosecond)
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:job_id, :seq])
    end)
  end
end)

# --- Summary ------------------------------------------------------------------
builds = Builds.list_for_pipeline(pipeline, Repo)

IO.puts("""

Seed complete.
  User:     #{user.email} (#{user.name})
  Org:      #{org.slug} (#{org.name}) — dev user is admin
  Token:    #{dev_token}  (Authorization: Bearer #{dev_token})
  Pipeline: #{pipeline.slug} (#{pipeline.name})
  Builds:   #{length(builds)} (#{builds |> Enum.map(& &1.state) |> Enum.join(", ")})
""")
