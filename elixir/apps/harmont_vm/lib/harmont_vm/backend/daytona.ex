defmodule HarmontVm.Backend.Daytona do
  @moduledoc """
  Daytona VM backend. Sandboxes are handed out two ways, because Daytona's
  `experimental` region has two distinct constraints:

    * `provision/1` with **no parent** (the render/discovery + fresh-job path)
      CREATES a fresh sandbox directly from the disk snapshot and verifies the
      baked overlay before handing it out. We cannot fork here: Daytona rejects
      fork on these sandboxes with `400 "Forking is not supported for this
      sandbox"`, which broke ~100% of GitHub-webhook pipeline discovery after the
      Daytona cutover. So instead we guard the **unreliable from-snapshot
      restore**: ~42-58% of `POST /sandbox {snapshot}` come up as the bare base
      image with the baked `/usr/local/bin` overlay (`hm`, `harmont-agent`)
      silently missing, surfacing downstream as `exit 127: command not found:
      hm`. `create_verified_job/2` creates a `harmont=job` sandbox, waits
      `started`, PROBES the overlay (`/usr/local/bin/hm` + `harmont-agent`), and
      tears down + retries any bad restore — the same probe-and-retry the old
      warm-template bake used, but the sandbox is born ready to serve (no
      template, no fork, no promotion).

    * `provision/1` with `parent_snapshot` set FORKS that parent (the `builds_in`
      lineage step). Fork here is a node-local COW of a live, already-good
      filesystem and remains the path for chained steps. **Unchanged** — whether
      this fork must also move off fork is a separate follow-up gated on a live
      Daytona spike.

  Every provisioned sandbox is labelled `harmont=job` (the create body sets it
  directly; `label_as_job/2` re-asserts it for the fork path, which inherits the
  parent's labels). That makes the build-terminal reap and the `SandboxReaper`
  responsible for cleanup. `snapshot/1` returns the live sandbox id (the fork
  source — no API call); the engine keeps fork-source parents alive (see
  `fork_source_is_live_vm?/0`) and reaps the fork tree at build-terminal. All
  sandboxes are `experimental`-target and **ephemeral** (`autoDeleteInterval: 0`)
  — required for the org's 30 GB disk grant (non-ephemeral caps at 20 GB);
  CPU/RAM/disk come from the baked snapshot, since create cannot request them.

  Config (`:harmont_vm, HarmontVm.Backend.Daytona`): `:api_key` (required),
  `:snapshot` (required — the baked runner snapshot name), `:target`
  (default "experimental"), `:control_base`/`:toolbox_base` (optional overrides),
  `:req_options` (tests inject Req.Test).
  """
  @behaviour HarmontVm.Backend

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias HarmontVm.Backend.Daytona.Client

  @provision_timeout_ms 120_000
  @poll_interval_ms 1_000
  @exec_slack_ms 60_000
  @fork_max_retries 30
  @default_control_base "https://app.daytona.io/api"
  @default_toolbox_base "https://proxy.app.daytona.io/toolbox"
  # Page size for the Daytona sandbox list. The endpoint hard-caps a single GET,
  # so list_sandbox_pages/2 walks `page=1..N` accumulating until a short page.
  @list_page_size 100

  # Legacy template labels — no longer minted (the warm-template fork path is
  # gone; see the moduledoc), but kept so list_managed_sandboxes/0 still reports
  # any pre-existing template/pending sandboxes left over from before the switch,
  # which the SandboxReaper then GCs by snapshot mismatch.
  @template_label "template"
  @template_pending_label "template-pending"
  # `-s` (non-empty) as well as `-x` (executable): a from-snapshot restore has
  # shipped a 0-byte-but-executable `hm`/`harmont-agent` (an empty file runs as an
  # empty script — exit 0, no output — yielding empty IR downstream). `-x` alone
  # passes that; require non-empty so a truncated overlay is rejected and rebaked.
  @overlay_probe "test -s /usr/local/bin/hm && test -x /usr/local/bin/hm && test -s /usr/local/bin/harmont-agent && test -x /usr/local/bin/harmont-agent"
  @overlay_probe_cap_ms 30_000

  @impl true
  def fork_source_is_live_vm?, do: true

  @impl true
  def provision(spec) do
    client = client()

    # The Daytona backend's flakiness (from-snapshot restore is ~58% bad, fork
    # contention under bursts) lives in the orchestration BETWEEN HTTP calls —
    # the per-request `:telemetry.span`s in Client can't show whether a slow/failed
    # provision was the template bake, fork contention, or the overlay probe. One
    # vm.provision parent span (with vm.fork / vm.template_bake children) makes
    # that semantic.
    Tracer.with_span "vm.provision", %{attributes: provision_attrs(spec)} do
      with {:ok, %{"id" => id}} <- create_or_fork(client, spec),
           :ok <- label_as_job(client, id),
           :ok <- ensure_started(client, id, deadline()) do
        Tracer.set_attribute("harmont.sandbox.id", id)
        {:ok, %{client: client, sandbox_id: id}}
      else
        {:error, e} ->
          Tracer.set_attribute("harmont.error.code", error_code(e))
          Tracer.set_status(OpenTelemetry.status(:error, error_code(e)))
          {:error, {:provision_failed, e}}
      end
    end
  end

  # `spec[:name]` is the job id (Session passes it); `parent_snapshot` is set for a
  # builds_in fork. Both bounded — no secrets. Drop nil keys.
  defp provision_attrs(spec) do
    %{
      "provision.had_parent" => is_binary(spec[:parent_snapshot]),
      "harmont.job.id" => spec[:name]
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp error_code(%{code: c}) when is_binary(c), do: c
  defp error_code(_), do: "provision_failed"

  # A fork INHERITS its parent's labels, and Daytona ignores a label override in
  # the fork body — so a job sandbox forked from the template comes up labelled
  # `harmont=template` and masquerades as one in find_template/2 (which then hands
  # the doomed job-fork to another provision -> 404 when it's reaped). Relabel
  # every provisioned sandbox to `harmont=job` BEFORE it reaches `started`, so it
  # is never a fork target and the SandboxReaper reaps it. Best-effort: a job
  # that runs is better than one failed over a label, and the dominant path is
  # reliable; a rare miss is swept later by snapshot mismatch.
  defp label_as_job(client, id) do
    _ =
      Client.request(
        client,
        :put,
        control_url("sandbox/#{id}/labels"),
        [json: %{labels: %{"harmont" => "job"}}],
        "daytona.job.label"
      )

    :ok
  end

  defp create_or_fork(client, %{parent_snapshot: parent} = spec) when is_binary(parent),
    do: fork_with_retry(client, parent, spec[:name], @fork_max_retries)

  # No parent: create a fresh sandbox DIRECTLY from the snapshot and verify the
  # baked overlay with retry. We do NOT fork — Daytona rejects fork on these
  # sandboxes with 400 "Forking is not supported for this sandbox", which broke
  # ~100% of GitHub-webhook pipeline discovery. See create_verified_job/2.
  defp create_or_fork(client, spec), do: create_verified_job(client, spec)

  # ── create-from-snapshot, overlay-verified ─────────────────────────
  #
  # Create a fresh sandbox DIRECTLY from the snapshot for a no-parent provision,
  # verifying the baked overlay and retrying past the ~42-58% bad-restore rate —
  # the same guard the template bake used, but the sandbox is born `harmont=job`
  # (never promoted, reaped by the SandboxReaper) and we never fork. Fork is
  # rejected by Daytona ("Forking is not supported for this sandbox").
  # Overlay-restore retries: each one BOOTS a VM (create → start → probe), so this
  # is the EXPENSIVE budget — guards the ~42-58% base-image-only bad-restore.
  @create_verify_attempts 8
  # Transient create-400 retries ("Sandbox failed to start: internal error"). These
  # are CHEAP (an immediate 400, no VM boot) and Daytona-side flaky (~70% fail on
  # 2026-06-11), so they get a SEPARATE, larger budget and must NOT
  # consume the overlay budget — otherwise a run of 400s starves the overlay guard.
  @create_retry_attempts 12

  defp create_verified_job(client, spec) do
    Tracer.with_span "vm.create_verified", %{} do
      do_create_verified_job(client, spec, @create_verify_attempts, @create_retry_attempts)
    end
  end

  defp do_create_verified_job(_client, _spec, 0, _create_tries) do
    Tracer.set_attribute("create.overlay_verified", false)
    Tracer.set_status(OpenTelemetry.status(:error, "snapshot_overlay_unavailable"))

    {:error,
     %{
       code: "snapshot_overlay_unavailable",
       message:
         "Daytona snapshot restore did not yield the runner overlay " <>
           "(#{@overlay_probe}) after #{@create_verify_attempts} attempts"
     }}
  end

  defp do_create_verified_job(client, spec, attempts, create_tries) do
    case create_job_sandbox(client, spec) do
      {:ok, %{"id" => id}} ->
        verify_job(client, spec, id, attempts, create_tries)

      # Daytona intermittently 400s the create itself with "Sandbox failed to
      # start: internal error" — a transient runner-side fault, NOT a client or
      # snapshot problem: the same call against the same active snapshot succeeds
      # on a later attempt (~70% fail rate observed 2026-06-11).
      # create_job_sandbox already reaped the orphaned error-sandbox, so burn a
      # CREATE attempt (not the overlay budget) and retry rather than failing the
      # build. Genuine errors (bad snapshot, auth, quota) are surfaced — not
      # transient, so they fall straight through.
      {:error, e} ->
        if transient_create_error?(e) and create_tries > 1 do
          Tracer.add_event("create.retry", %{
            "create.attempts_remaining" => create_tries - 1,
            "create.error" => Map.get(e, :message, "")
          })

          do_create_verified_job(client, spec, attempts, create_tries - 1)
        else
          {:error, e}
        end
    end
  end

  # The transient Daytona create fault (see do_create_verified_job): a 400 whose
  # message is "Sandbox failed to start: internal error", the ~70% intermittent
  # runner fault. Matched on message so genuine errors (bad snapshot,
  # quota, auth) are NOT retried. A 409 "already exists" is NOT retried — unique
  # per-attempt names make it impossible, so a 409 would signal a real bug, not a
  # transient, and should surface fast rather than spin the whole retry budget.
  defp transient_create_error?(%{message: msg}) when is_binary(msg),
    do: String.contains?(msg, "failed to start") or String.contains?(msg, "internal error")

  defp transient_create_error?(_), do: false

  defp verify_job(client, spec, id, attempts, create_tries) do
    case ensure_started(client, id, deadline()) do
      :ok ->
        if overlay_present?(client, id) do
          Tracer.set_attribute("create.overlay_verified", true)
          Tracer.set_attribute("create.attempts", @create_verify_attempts - attempts + 1)
          {:ok, %{"id" => id}}
        else
          # A base-image-only restore (the overlay silently dropped). Throw it
          # away and retry — this is the failure mode create+verify guards against.
          Tracer.add_event("create.restore_rejected", %{
            "create.attempts_remaining" => attempts - 1
          })

          teardown(%{client: client, sandbox_id: id})
          do_create_verified_job(client, spec, attempts - 1, create_tries)
        end

      # build_failed / error / provision timeout are not self-healing — clean up
      # and surface, rather than burning every retry on the same fault.
      {:error, e} ->
        teardown(%{client: client, sandbox_id: id})
        {:error, e}
    end
  end

  defp create_job_sandbox(client, spec) do
    # UNIQUE name per create attempt. Daytona has a vicious race: a transient
    # create 400 ("Sandbox failed to start: internal error") STILL leaves a
    # sandbox under the requested name in `creating` state — and Daytona refuses
    # to delete a `creating` sandbox — so a FIXED name (the job id) makes every
    # retry 409 "already exists" against the undead orphan, forever. A fresh name
    # each attempt sidesteps the collision entirely. The orphans are harmont-owned
    # but have no active registry row, so the hourly SandboxReaper GCs them (see
    # its moduledoc); we do NOT reap inline — that listed every sandbox on each
    # failed attempt and couldn't delete the `creating` orphan anyway.
    # Caching note: the sandbox NAME does not feed snapshot-fork caching (that
    # keys on the snapshot id), so a per-attempt name is safe.
    base = spec[:name] || "harmont-job"
    name = "#{base}-#{System.unique_integer([:positive])}"

    # Daytona class & disk model — every field here is load-bearing; do NOT add
    # `sandboxClass`, `disk`, `cpu`, or `memory`:
    #   * `sandboxClass` is a property of the SNAPSHOT (set only on
    #     POST /api/snapshots).
    #     CreateSandbox has NO sandboxClass field — a sandbox INHERITS the class of
    #     `snapshot`. Our runner snapshot is baked `linux-vm` (30 GiB). The 2026-06
    #     "Sandbox failed to start: internal error" outage was a `container`-class
    #     (10 GiB) snapshot; the fix is in the bake, not here.
    #   * Do NOT set `disk`/`cpu`/`memory`: Daytona 400s with "Cannot specify
    #     Sandbox resources when using a snapshot" — the sandbox inherits the
    #     snapshot's baked size (30 GiB). (This line previously set `disk: 30` and
    #     broke every create; the 30 GiB comes from the snapshot + ephemeral.)
    #   * "ephemeral" is not a field — it IS `autoDeleteInterval: 0`, which on a
    #     `linux-vm` snapshot unlocks the 30 GiB grant (non-ephemeral caps at 20).
    body = %{
      target: target(),
      snapshot: config()[:snapshot],
      autoStopInterval: 0,
      autoDeleteInterval: 0,
      name: name,
      labels: %{"harmont" => "job"}
    }

    # Orphaned `creating`/`error` sandboxes from a failed create are GC'd by the
    # hourly SandboxReaper (harmont-owned + no active registry row). We don't reap
    # inline — see the unique-name comment above.
    Client.request(client, :post, control_url("sandbox"), [json: body], "daytona.job.create")
  end

  defp overlay_present?(client, id) do
    case exec(%{client: client, sandbox_id: id}, %{
           command: @overlay_probe,
           hard_cap_ms: @overlay_probe_cap_ms
         }) do
      {:ok, %{exit_code: 0}} -> true
      _ -> false
    end
  end

  defp label(%{"labels" => l}, key) when is_map(l), do: l[key]
  defp label(_, _), do: nil

  # Forks of one template contend: while a sibling is forking it the parent is
  # transiently `forking` ("Sandbox must be in started state to fork"), and a
  # concurrent fork can lose an optimistic-concurrency check ("Sandbox was
  # modified by another operation"). Both are transient under a burst of job
  # provisions — retry with a JITTERED backoff so the herd de-syncs instead of
  # colliding on every round.
  # One span over the retry loop; the recursion (do_fork_with_retry/5) carries a
  # contention counter so fork.contention_retries / fork.attempts surface the
  # fork-storm contention that's otherwise only inferable from raw HTTP span
  # counts.
  defp fork_with_retry(client, parent, name, retries) do
    Tracer.with_span "vm.fork", %{} do
      do_fork_with_retry(client, parent, name, retries, 0)
    end
  end

  defp do_fork_with_retry(client, parent, name, retries, contention) do
    case Client.request(
           client,
           :post,
           control_url("sandbox/#{parent}/fork"),
           [json: %{name: name}],
           "daytona.sandbox.fork"
         ) do
      {:ok, %{"id" => _} = sb} ->
        Tracer.set_attribute("fork.contention_retries", contention)
        Tracer.set_attribute("fork.attempts", contention + 1)
        {:ok, sb}

      {:error, %{message: msg}} when retries > 0 ->
        if fork_contention?(msg) do
          Process.sleep(fork_retry_interval_ms() + :rand.uniform(fork_retry_interval_ms()))
          do_fork_with_retry(client, parent, name, retries - 1, contention + 1)
        else
          Tracer.set_status(OpenTelemetry.status(:error, "fork_failed"))
          {:error, %{code: "fork_failed", message: msg}}
        end

      {:error, e} ->
        {:error, e}
    end
  end

  # Transient errors a concurrent fork burst against one template throws; all
  # clear with a retry once the herd thins. "Required feature flags are not
  # enabled" is a (misleading) one Daytona returns under concurrent fork load on
  # the experimental fork path — verified retryable: 15 simultaneous forks failed
  # ~half with it, but retrying drove them through. It is NOT a real
  # missing-feature signal (the account HAS fork; the non-contended path works).
  @fork_contention_substrings [
    "started state",
    "modified by another operation",
    "Required feature flags are not enabled"
  ]

  defp fork_contention?(msg) do
    msg = msg || ""
    Enum.any?(@fork_contention_substrings, &String.contains?(msg, &1))
  end

  @impl true
  def exec(%{client: client, sandbox_id: id}, %{command: cmd, hard_cap_ms: cap}) do
    url = toolbox_url(id, "process/execute")

    opts = [
      json: %{command: cmd, timeout: div(cap + @exec_slack_ms, 1000)},
      receive_timeout: cap + @exec_slack_ms
    ]

    case Client.request(client, :post, url, opts, "daytona.process.execute") do
      {:ok, %{"exitCode" => code} = r} ->
        {:ok, %{exit_code: code, stdout: r["result"] || "", stderr: ""}}

      {:ok, r} ->
        {:error, {:exec_failed, %{code: "missing_exit_code", message: inspect(r)}}}

      {:error, e} ->
        {:error, {:exec_failed, e}}
    end
  end

  # The live sandbox IS the fork source — no separate artifact, no slow copy.
  @impl true
  def snapshot(%{sandbox_id: id}), do: {:ok, id}

  @impl true
  def delete_snapshot(sandbox_id) do
    _ =
      Client.request(
        client(),
        :delete,
        control_url("sandbox/#{sandbox_id}"),
        [],
        "daytona.sandbox.delete"
      )

    :ok
  end

  @impl true
  def teardown(%{client: client, sandbox_id: id}) do
    _ =
      Client.request(client, :delete, control_url("sandbox/#{id}"), [], "daytona.sandbox.delete")

    :ok
  end

  @impl true
  def list_managed_sandboxes do
    case list_sandbox_pages(client(), "daytona.sandbox.list") do
      {:ok, items} ->
        {:ok,
         items
         |> Enum.filter(&harmont_owned?/1)
         |> Enum.map(
           &%{
             id: &1["id"],
             kind: kind_from_labels(&1),
             snapshot_label: label(&1, "harmont_snapshot"),
             create_time_ms: created_ms(&1),
             state: &1["state"]
           }
         )}

      {:error, e} ->
        {:error, e}
    end
  end

  # Daytona's sandbox list is page-capped at @list_page_size, so a single GET sees
  # at most that many sandboxes — past which leaked job sandboxes become invisible
  # to the SandboxReaper and stale templates to find_template/2. Walk the pages
  # (1-based `page` + `limit`), accumulating items until a page comes back short
  # of the limit (the last page), then return the full set. Any page erroring
  # aborts the whole walk so callers never act on a partial list (a truncated list
  # would make the reaper mass-mark live sandboxes "deleted").
  defp list_sandbox_pages(client, span_name), do: list_sandbox_pages(client, span_name, 1, [])

  defp list_sandbox_pages(client, span_name, page, acc) do
    url = control_url("sandbox?limit=#{@list_page_size}&page=#{page}")

    case Client.request(client, :get, url, [], span_name) do
      {:ok, %{"items" => items}} when is_list(items) ->
        acc = acc ++ items

        if length(items) < @list_page_size,
          do: {:ok, acc},
          else: list_sandbox_pages(client, span_name, page + 1, acc)

      {:ok, _} ->
        {:ok, acc}

      {:error, e} ->
        {:error, e}
    end
  end

  @impl true
  def handle_id(%{sandbox_id: id}), do: id

  # ── helpers ────────────────────────────────────────────────────────

  defp deadline, do: System.monotonic_time(:millisecond) + @provision_timeout_ms

  defp ensure_started(client, id, deadline) do
    case Client.request(
           client,
           :get,
           control_url("sandbox/#{id}"),
           [],
           "daytona.sandbox.get"
         ) do
      {:ok, %{"state" => "started"}} ->
        :ok

      {:ok, %{"state" => s}} when s in ["error", "build_failed"] ->
        {:error, %{code: "sandbox_#{s}", message: "sandbox entered #{s}"}}

      {:ok, _provisioning} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, %{code: "provision_timeout", message: "sandbox not started within deadline"}}
        else
          Process.sleep(@poll_interval_ms)
          ensure_started(client, id, deadline)
        end

      {:error, e} ->
        {:error, e}
    end
  end

  defp harmont_owned?(%{"labels" => l}) when is_map(l), do: Map.has_key?(l, "harmont")
  defp harmont_owned?(_), do: false

  defp kind_from_labels(s) do
    case label(s, "harmont") do
      "job" -> :job
      @template_label -> :template
      @template_pending_label -> :template_pending
      _ -> :unknown
    end
  end

  defp created_ms(%{"createdAt" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end

  defp created_ms(_), do: 0

  defp config, do: Application.fetch_env!(:harmont_vm, __MODULE__)
  defp client, do: Client.new(config())
  defp target, do: config()[:target] || "experimental"
  defp control_base, do: config()[:control_base] || @default_control_base
  defp toolbox_base, do: config()[:toolbox_base] || @default_toolbox_base
  defp control_url(path), do: "#{control_base()}/#{path}"
  defp toolbox_url(id, path), do: "#{toolbox_base()}/#{id}/#{path}"
  defp fork_retry_interval_ms, do: Application.get_env(:harmont_vm, :fork_retry_interval_ms, 500)
end
