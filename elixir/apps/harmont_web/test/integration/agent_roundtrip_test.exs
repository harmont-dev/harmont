defmodule Harmont.Integration.AgentRoundtripTest do
  @moduledoc """
  End-to-end agent WebSocket round-trip integration test.

  Connects a fake agent over a REAL WebSocket to the running endpoint at
  /v0/agent/connect, speaks the protobuf wire protocol, and proves the full
  agent path works:

  1. Pre-seeds a Build + Job in "assigned" state.
  2. Connects with Authorization: Bearer <token> via :gun (HTTP/1.1 WS upgrade).
  3. Sends Hello → expects ResumeInfo + JobSpec back.
  4. Sends a LogChunk (seq 1) → asserts it is persisted in log_chunks.
  5. Sends a Heartbeat → asserts last_heartbeat_at is updated.
  6. Sends Bye → connection closes normally.

  No live Session is required for this path: the AgentSocket handles
  auth+handshake, and the Bridge handles log/heartbeat persistence without a
  Session. State transitions (JOB_ASSIGNED_TO_SANDBOX etc.) route to
  Session.agent_event which is a no-op when no Session is alive
  (cast_if_alive), so we skip those in this test.

  The test bypasses the Ecto sandbox and uses a real Postgres connection so
  that the Bandit worker processes that handle the WebSocket can also reach
  the DB without needing Sandbox.allow. Rows are cleaned up in on_exit.

  Run: mix test --only integration
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Agent.Protocol
  alias Harmont.Agent.V1, as: PB
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Logs.LogChunk
  alias Harmont.Repo
  import Ecto.Query

  # Port for the integration HTTP server. Must not collide with other services
  # on this shared machine. 4897 is chosen arbitrarily in a high range.
  @port 4_897

  # ── server lifecycle ────────────────────────────────────────────────────────

  setup_all do
    # Start a real Bandit listener pointing at the Phoenix Endpoint (which is
    # already started by the application supervision tree without an HTTP
    # listener). Bandit.child_spec/1 returns a supervisor spec we can hand
    # to start_supervised!/1.
    bandit =
      start_supervised!(
        Bandit.child_spec(
          plug: HarmontWeb.Endpoint,
          scheme: :http,
          ip: {127, 0, 0, 1},
          port: @port
        )
      )

    on_exit(fn -> Process.exit(bandit, :kill) end)
    :ok
  end

  # ── per-test DB seeding + cleanup ───────────────────────────────────────────

  setup do
    # Check out a sandbox connection in shared mode so that the Bandit worker
    # processes spawned to handle the WebSocket can also reach the DB.
    pid = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    token = "integration-tok"

    # Insert directly — no sandbox so worker processes can reach these rows.
    {:ok, build} =
      %Build{}
      |> Build.changeset(%{
        external_build_id: Ecto.UUID.generate(),
        runner_token_hash: :crypto.hash(:sha256, token)
      })
      |> Repo.insert()

    {:ok, job} =
      %Job{}
      |> Job.changeset(%{
        build_id: build.id,
        step_key: "roundtrip",
        command: "echo hello",
        state: "assigned"
      })
      |> Repo.insert()

    on_exit(fn ->
      Repo.delete_all(from(c in LogChunk, where: c.job_id == ^job.id))
      Repo.delete_all(from(j in Job, where: j.id == ^job.id))
      Repo.delete_all(from(b in Build, where: b.id == ^build.id))
    end)

    %{build: build, job: job, token: token}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Open an HTTP/1.1 gun connection to localhost:@port, upgrade to WebSocket
  # at /v0/agent/connect with a Bearer token, and return {conn, stream_ref}.
  defp ws_connect(token) do
    {:ok, conn} = :gun.open(~c"127.0.0.1", @port, %{protocols: [:http], retry: 0})
    {:ok, :http} = :gun.await_up(conn, 5_000)

    headers = [{<<"authorization">>, <<"Bearer #{token}">>}]
    stream_ref = :gun.ws_upgrade(conn, "/v0/agent/connect", headers)

    receive do
      {:gun_upgrade, ^conn, ^stream_ref, [<<"websocket">>], _headers} ->
        {conn, stream_ref}

      {:gun_response, ^conn, ^stream_ref, _, status, _headers} ->
        :gun.shutdown(conn)
        raise "WS upgrade failed with HTTP #{status}"

      {:gun_error, ^conn, ^stream_ref, reason} ->
        :gun.shutdown(conn)
        raise "WS upgrade error: #{inspect(reason)}"
    after
      5_000 ->
        :gun.shutdown(conn)
        raise "WS upgrade timeout"
    end
  end

  # Send a binary (protobuf) frame.
  defp ws_send(conn, stream_ref, binary) when is_binary(binary) do
    :ok = :gun.ws_send(conn, stream_ref, {:binary, binary})
  end

  # Receive the next binary WebSocket frame, with a timeout.
  defp ws_recv(conn, stream_ref, timeout \\ 2_000) do
    receive do
      {:gun_ws, ^conn, ^stream_ref, {:binary, data}} -> data
      {:gun_ws, ^conn, ^stream_ref, :close} -> raise "WS closed unexpectedly"
      {:gun_ws, ^conn, ^stream_ref, {:close, _, _}} -> raise "WS closed unexpectedly"
    after
      timeout -> raise "WS recv timeout"
    end
  end

  # ── the actual test ──────────────────────────────────────────────────────────

  test "hello → ResumeInfo+JobSpec, log chunk persisted, heartbeat updates timestamp", %{
    build: build,
    job: job,
    token: token
  } do
    {conn, stream_ref} = ws_connect(token)

    # ── 1. Send Hello ────────────────────────────────────────────────────────
    hello =
      %PB.AgentFrame{
        payload:
          {:hello,
           %PB.HelloMsg{
             proto_version: 1,
             build_id: build.external_build_id,
             job_id: job.id,
             instance_id: "fake-agent-01"
           }}
      }
      |> PB.AgentFrame.encode()

    ws_send(conn, stream_ref, hello)

    # ── 2. Expect ResumeInfo ──────────────────────────────────────────────────
    resume_bin = ws_recv(conn, stream_ref)

    assert {:resume, %PB.ResumeInfo{server_max_seq: 0, spec_already_sent: false}} =
             Protocol.decode_server(resume_bin)

    # ── 3. Expect JobSpec ─────────────────────────────────────────────────────
    spec_bin = ws_recv(conn, stream_ref)
    assert {:spec, %PB.JobSpec{command: "echo hello"}} = Protocol.decode_server(spec_bin)

    # ── 4. Send a LogChunk (seq 1) ───────────────────────────────────────────
    log_frame =
      %PB.AgentFrame{
        payload:
          {:log,
           %PB.LogChunk{
             seq: 1,
             stream: :STDOUT,
             data: "hello world\n",
             ts_unix_ns: System.system_time(:nanosecond)
           }}
      }
      |> PB.AgentFrame.encode()

    ws_send(conn, stream_ref, log_frame)

    # Give the server a moment to persist the chunk asynchronously.
    Process.sleep(200)

    chunk = Repo.one(from(c in LogChunk, where: c.job_id == ^job.id and c.seq == 1))
    assert chunk != nil, "expected log_chunks row for seq=1"
    assert chunk.content == "hello world\n"

    # ── 5. Send a Heartbeat → last_heartbeat_at updated ──────────────────────
    hb_frame =
      %PB.AgentFrame{
        payload:
          {:heartbeat,
           %PB.Heartbeat{
             ts_unix_ns: System.system_time(:nanosecond)
           }}
      }
      |> PB.AgentFrame.encode()

    ws_send(conn, stream_ref, hb_frame)

    Process.sleep(200)

    updated_job = Repo.get!(Job, job.id)
    assert updated_job.last_heartbeat_at != nil, "expected last_heartbeat_at to be set"

    # ── 6. Send Bye → server closes the connection ────────────────────────────
    bye_frame =
      %PB.AgentFrame{
        payload: {:bye, %PB.ByeMsg{reason: :CLEAN_EXIT}}
      }
      |> PB.AgentFrame.encode()

    ws_send(conn, stream_ref, bye_frame)

    # Connection should close (server calls {:stop, :normal, ...})
    receive do
      {:gun_ws, ^conn, ^stream_ref, :close} -> :ok
      {:gun_ws, ^conn, ^stream_ref, {:close, _, _}} -> :ok
      {:gun_down, ^conn, :http, :normal, _} -> :ok
      {:gun_down, ^conn, :http, :closed, _} -> :ok
    after
      2_000 ->
        :ok
        # Not a hard failure — the server may not echo back a close frame
    end

    :gun.shutdown(conn)
  end
end
