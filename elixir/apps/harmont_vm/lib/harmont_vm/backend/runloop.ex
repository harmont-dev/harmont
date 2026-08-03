defmodule HarmontVm.Backend.Runloop do
  @moduledoc """
  Production VM backend on the Runloop Devbox API (https://api.runloop.ai).

  This module is a thin mapper: it turns the behaviour's `spec`/`exec_opts` into
  Runloop devbox requests and maps responses back to the behaviour's result
  shapes. All transport (auth, retry, telemetry, JSON decode, error rendering)
  lives in `HarmontVm.Backend.Runloop.Client`, which is independently testable.

  Handle = `%{client: Client.t(), devbox_id: String.t()}`. A devbox is created
  at the smallest *named* Runloop size that satisfies the requested cpu/memory,
  polled until `running` (the session calls `provision` then `exec` with no
  intervening `await_ready`, so readiness must be guaranteed before `provision/1`
  returns), driven via `execute_sync`, and snapshotted via `snapshot_disk`.
  Errors surface as `{:error, {tag, %{code, message}}}`.

  Named sizes (not `CUSTOM_SIZE`) are used because trial accounts forbid
  `CUSTOM_SIZE`. The downside: disk is fixed per named size, so `spec.disk_gb` is
  advisory (e.g. MEDIUM = 8 GiB disk). Precise disk needs a fully-paid (non-trial)
  account and a re-introduced custom path.

  Config (this package's own app env):

      config :harmont_vm, HarmontVm.Backend.Runloop,
        api_key: System.fetch_env!("RUNLOOP_API_KEY"),
        blueprint_id: System.get_env("RUNLOOP_BLUEPRINT_ID"), # optional base image
        base_url: "https://api.runloop.ai",                   # optional override
        resource_size: "LARGE",                               # optional; pins the size
        keep_alive_seconds: 14_400,                           # optional; non-trial above 3600
        req_options: []                                       # optional; tests inject Req.Test
  """
  @behaviour HarmontVm.Backend

  require Logger

  alias HarmontVm.Backend.Runloop.Client

  @provision_timeout_ms 180_000
  @poll_interval_ms 1_000
  # Deadline for an async disk snapshot to reach `complete` (big cargo targets
  # take minutes); the status poll interval is `snapshot_poll_interval_ms/0`.
  @snapshot_ready_timeout_ms 600_000
  # execute_sync holds the HTTP connection open for the whole command; give Req
  # headroom over the caller's hard cap so the socket outlives the command.
  @exec_slack_ms 60_000
  # Backstop TTL on a devbox (the engine tears down explicitly via teardown/1).
  # 3600s is the trial-account ceiling; non-trial accounts running long jobs
  # should raise it above their max job duration via the :keep_alive_seconds config.
  @default_keep_alive_seconds 3600

  # Runloop named devbox sizes as {name, cpu_cores, gib_ram}, ascending. We map
  # the requested cpu/memory to the smallest size that satisfies both. CUSTOM_SIZE
  # is intentionally not used (non-trial-only; trial accounts reject it).
  @named_sizes [
    {"X_SMALL", 0.5, 1},
    {"SMALL", 1, 2},
    {"MEDIUM", 2, 4},
    {"LARGE", 2, 8},
    {"X_LARGE", 4, 16},
    {"XX_LARGE", 8, 32}
  ]

  @impl true
  def provision(spec) do
    client = client()

    body =
      %{
        name: spec[:name],
        launch_parameters: %{
          resource_size_request: resource_size(spec),
          keep_alive_time_seconds: keep_alive_seconds()
        }
      }
      |> put_source(spec)

    case Client.request(client, :post, "/v1/devboxes", [json: body], "runloop.devbox.create") do
      {:ok, %{"id" => id} = dbx} ->
        handle = %{client: client, devbox_id: id}

        case ensure_running(handle, dbx, @provision_timeout_ms) do
          :ok -> {:ok, handle}
          {:error, e} -> {:error, {:provision_failed, e}}
        end

      {:error, e} ->
        {:error, {:provision_failed, e}}
    end
  end

  # A configured :resource_size pins the size (ops knob, e.g. force LARGE for CI);
  # otherwise derive the smallest named size that fits the requested cpu/memory.
  defp resource_size(spec) do
    config()[:resource_size] || smallest_fitting_size(spec.cpu_count, spec.memory_gb)
  end

  defp smallest_fitting_size(cpu, memory_gb) do
    Enum.find_value(@named_sizes, "XX_LARGE", fn {name, cores, gib} ->
      if cores >= cpu and gib >= memory_gb, do: name
    end)
  end

  defp keep_alive_seconds, do: config()[:keep_alive_seconds] || @default_keep_alive_seconds

  # parent_snapshot (cache fork) > base_snapshot > configured blueprint.
  defp put_source(body, spec) do
    cond do
      sid = spec[:parent_snapshot] || spec[:base_snapshot] -> Map.put(body, :snapshot_id, sid)
      bp = config()[:blueprint_id] -> Map.put(body, :blueprint_id, bp)
      true -> body
    end
  end

  @impl true
  def await_ready(%{} = handle, timeout_ms) do
    case ensure_running(handle, nil, timeout_ms) do
      :ok -> :ok
      {:error, e} -> {:error, {:provision_failed, e}}
    end
  end

  # If we already hold a body that's running, done. Otherwise poll GET.
  defp ensure_running(_handle, %{"status" => "running"}, _timeout_ms), do: :ok

  defp ensure_running(handle, _dbx, timeout_ms) do
    poll_running(handle, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll_running(%{client: client, devbox_id: id} = handle, deadline) do
    case Client.request(client, :get, "/v1/devboxes/#{id}", [], "runloop.devbox.get") do
      {:ok, %{"status" => "running"}} ->
        :ok

      {:ok, %{"status" => status}} when status in ["failure", "shutdown"] ->
        {:error, %{code: "devbox_#{status}", message: "devbox entered #{status} before ready"}}

      {:ok, _provisioning} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, %{code: "provision_timeout", message: "devbox not running within deadline"}}
        else
          Process.sleep(@poll_interval_ms)
          poll_running(handle, deadline)
        end

      {:error, e} ->
        {:error, e}
    end
  end

  @impl true
  def exec(%{client: client, devbox_id: id}, %{command: cmd, hard_cap_ms: cap}) do
    # execute_sync has no body-level timeout; the client receive_timeout is the
    # only lever, so size it above the caller's hard cap.
    opts = [json: %{command: cmd}, receive_timeout: cap + @exec_slack_ms]

    case Client.request(
           client,
           :post,
           "/v1/devboxes/#{id}/execute_sync",
           opts,
           "runloop.devbox.exec"
         ) do
      {:ok, %{"exit_status" => code} = r} ->
        {:ok, %{exit_code: code, stdout: r["stdout"] || "", stderr: r["stderr"] || ""}}

      {:ok, r} ->
        # A 2xx body without exit_status is malformed; surface it as a failure
        # rather than crashing the session with a CaseClauseError.
        {:error, {:exec_failed, %{code: "missing_exit_status", message: inspect(r)}}}

      {:error, e} ->
        {:error, {:exec_failed, e}}
    end
  end

  @impl true
  def snapshot(%{client: client, devbox_id: id}) do
    # `snapshot_disk` blocks server-side for the WHOLE disk copy (~60s/2GB — well
    # past Req's default receive_timeout), and `retry: :transient` would re-fire
    # on the timeout, creating duplicate snapshots and still failing. Kick the
    # snapshot off ASYNC (returns the id immediately; `retry: false` because
    # creating a snapshot is not idempotent) and poll its status to `complete`.
    case Client.request(
           client,
           :post,
           "/v1/devboxes/#{id}/snapshot_disk_async",
           [json: %{}, retry: false],
           "runloop.devbox.snapshot"
         ) do
      {:ok, %{"id" => sid}} ->
        deadline = System.monotonic_time(:millisecond) + @snapshot_ready_timeout_ms

        case await_snapshot_complete(client, sid, deadline) do
          :ok -> {:ok, sid}
          {:error, e} -> {:error, {:snapshot_failed, e}}
        end

      {:ok, other} ->
        {:error, {:snapshot_failed, %{code: "missing_id", message: inspect(other)}}}

      {:error, e} ->
        {:error, {:snapshot_failed, e}}
    end
  end

  # Poll GET /disk_snapshots/{id}/status until the async snapshot is `complete`.
  # `error`/`failed` -> fail loud; past the deadline -> timeout. Short GETs, so no
  # long-held connection and no retry-storm.
  defp await_snapshot_complete(client, sid, deadline) do
    case Client.request(
           client,
           :get,
           "/v1/devboxes/disk_snapshots/#{sid}/status",
           [],
           "runloop.devbox.snapshot_status"
         ) do
      {:ok, %{"status" => "complete"}} ->
        :ok

      {:ok, %{"status" => status}} when status in ["error", "failed"] ->
        {:error, %{code: "snapshot_#{status}", message: "snapshot #{sid} entered #{status}"}}

      {:ok, _in_progress} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error,
           %{code: "snapshot_timeout", message: "snapshot #{sid} not complete within deadline"}}
        else
          Process.sleep(snapshot_poll_interval_ms())
          await_snapshot_complete(client, sid, deadline)
        end

      {:error, e} ->
        {:error, e}
    end
  end

  defp snapshot_poll_interval_ms,
    do: Application.get_env(:harmont_vm, :snapshot_poll_interval_ms, 2_000)

  @impl true
  def delete_snapshot(snapshot_id) do
    _ =
      Client.request(
        client(),
        :post,
        "/v1/devboxes/disk_snapshots/#{snapshot_id}/delete",
        [json: %{}],
        "runloop.devbox.delete_snapshot"
      )

    :ok
  end

  # Runloop paginates this endpoint; we page in chunks and a stale snapshot
  # missed on one sweep is caught on the next (the sweeper runs hourly).
  @list_limit 100

  @impl true
  def list_snapshots do
    case Client.request(
           client(),
           :get,
           "/v1/devboxes/disk_snapshots?limit=#{@list_limit}",
           [],
           "runloop.devbox.list_snapshots"
         ) do
      {:ok, %{"snapshots" => snaps}} when is_list(snaps) ->
        if length(snaps) >= @list_limit do
          Logger.warning(
            "runloop list_snapshots hit the #{@list_limit}-item page limit; " <>
              "older snapshots (if any) are swept on a later run"
          )
        end

        {:ok, Enum.map(snaps, &%{id: &1["id"], create_time_ms: &1["create_time_ms"] || 0})}

      {:ok, _other} ->
        {:ok, []}

      {:error, e} ->
        {:error, e}
    end
  end

  @impl true
  def teardown(%{client: client, devbox_id: id}) do
    _ =
      Client.request(
        client,
        :post,
        "/v1/devboxes/#{id}/shutdown",
        [json: %{}],
        "runloop.devbox.shutdown"
      )

    :ok
  end

  @impl true
  def handle_id(%{devbox_id: id}), do: id

  # ── helpers ────────────────────────────────────────────────────────

  defp config, do: Application.fetch_env!(:harmont_vm, __MODULE__)

  defp client, do: Client.new(config())
end
