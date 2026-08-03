defmodule HarmontVm.Backend.Runloop.IntegrationTest do
  @moduledoc """
  Live, real-API integration suite for the Runloop backend. Excluded from the
  default `mix test` run via the `:integration` tag; run it explicitly:

      mix test --only integration apps/harmont_vm/test/harmont_vm/backend/runloop/integration_test.exs

  ## Credentials

  The API key is read from a Secret Manager secret via `gcloud` (name it with
  `RUNLOOP_SECRET_NAME`, default `runloop-api-key`), or supply it directly in
  `RUNLOOP_API_KEY`:

      gcloud secrets versions access latest --secret="$RUNLOOP_SECRET_NAME"

  `gcloud`'s active project is used (`gcloud config get-value project`); override
  with `HARMONT_GCP_PROJECT`. A pre-fetched key in `RUNLOOP_API_KEY` short-circuits
  the gcloud call (handy for CI). If no key can be obtained (gcloud missing,
  unauthenticated, or the secret does not exist yet), every test is a trivial
  pass — the suite is gated at runtime, so there is no stale-compile footgun and
  no accidental spend.

  ## What it exercises

  The full shipped code path — `HarmontVm.Backend.Runloop.provision/1` (which
  polls the real devbox until `running`) → `exec/2` → `snapshot/1` →
  `delete_snapshot/1` → `teardown/1` — against the real API. This is what
  validates the wire contract the stubbed unit tests can only assume (field
  names like `exit_status`, the `running` status string, snapshot-on-running,
  real auth/retry). The devbox + snapshot are always cleaned up via `on_exit`,
  even on mid-test failure.

  `async: false` + a generous timeout because provisioning a real VM takes
  several seconds to ~a minute.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: :timer.minutes(5)

  alias HarmontVm.Backend.Runloop

  @default_secret "runloop-api-key"

  setup do
    case fetch_key() do
      nil ->
        # Gated: no key, no live calls. Tests below no-op via `with_key/2`.
        :ok

      key ->
        # Point the backend at the real API for this run: drop the Req.Test plug
        # the default test config injects and use the live key. Restored after.
        prev = Application.get_env(:harmont_vm, Runloop)
        Application.put_env(:harmont_vm, Runloop, api_key: key)
        on_exit(fn -> Application.put_env(:harmont_vm, Runloop, prev) end)
        {:ok, key: key}
    end
  end

  test "provision -> exec -> snapshot -> delete_snapshot -> teardown round-trips against the live API",
       ctx do
    with_key(ctx, fn ->
      spec = %{
        # 1 cpu / 2 GiB maps to the SMALL named size — the cheapest size a trial
        # account allows. disk_gb is advisory (named sizes have fixed disk).
        cpu_count: 1,
        memory_gb: 2.0,
        disk_gb: 2.0,
        name: unique("hm-itest"),
        base_snapshot: nil,
        parent_snapshot: nil
      }

      assert {:ok, %{devbox_id: id} = handle} = Runloop.provision(spec)
      on_exit(fn -> Runloop.teardown(handle) end)
      assert is_binary(id) and id != ""

      # await_ready must be idempotent once provision has already reached running.
      assert :ok = Runloop.await_ready(handle, 30_000)

      assert {:ok, %{exit_code: 0, stdout: out}} =
               Runloop.exec(handle, %{command: "echo hi", hard_cap_ms: 60_000})

      assert out =~ "hi"

      assert {:ok, snapshot_id} = Runloop.snapshot(handle)
      on_exit(fn -> Runloop.delete_snapshot(snapshot_id) end)
      assert is_binary(snapshot_id) and snapshot_id != ""

      assert :ok = Runloop.delete_snapshot(snapshot_id)
      assert :ok = Runloop.teardown(handle)
    end)
  end

  # Runs `fun.()` only when a key is configured; otherwise no-ops (gated).
  defp with_key(ctx, fun) do
    if Map.has_key?(ctx, :key), do: fun.(), else: :ok
  end

  defp unique(prefix), do: "#{prefix}-#{System.system_time(:second)}"

  # Prefer a pre-supplied env key (CI), else read the gcloud secret. Any failure
  # (gcloud absent/unauthenticated, secret missing) yields nil → gated no-op.
  defp fetch_key do
    case System.get_env("RUNLOOP_API_KEY") do
      key when is_binary(key) and key != "" -> key
      _ -> fetch_key_from_gcloud()
    end
  end

  defp fetch_key_from_gcloud do
    secret = System.get_env("RUNLOOP_SECRET_NAME") || @default_secret
    args = ["secrets", "versions", "access", "latest", "--secret=#{secret}"]

    args =
      if p = System.get_env("HARMONT_GCP_PROJECT"), do: args ++ ["--project=#{p}"], else: args

    case System.cmd("gcloud", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    # gcloud not installed / not on PATH.
    _ -> nil
  end
end
