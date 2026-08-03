defmodule HarmontWeb.AgentSocketTest do
  use Harmont.DataCase, async: false
  alias Harmont.Agent.Protocol
  alias Harmont.Agent.V1, as: PB
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Repo
  alias HarmontWeb.AgentSocket

  defmodule HeartbeatSilentBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_spec), do: {:ok, %{vm: "silent"}}
    @impl true
    def exec(_h, _o), do: Process.sleep(:infinity)
    @impl true
    def teardown(_h), do: :ok
  end

  setup do
    token = "tok"

    {:ok, b} =
      %Build{}
      |> Build.changeset(%{
        external_build_id: Ecto.UUID.generate(),
        runner_token_hash: :crypto.hash(:sha256, token)
      })
      |> Repo.insert()

    {:ok, j} =
      %Job{}
      |> Job.changeset(%{build_id: b.id, step_key: "a", command: "echo x", state: "assigned"})
      |> Repo.insert()

    %{build: b, job: j, token: token}
  end

  test "hello with valid token pushes ResumeInfo + JobSpec", %{
    build: b,
    job: j,
    token: token
  } do
    {:ok, state} = AgentSocket.init(token: token)

    hello = %PB.AgentFrame{
      payload:
        {:hello,
         %PB.HelloMsg{
           proto_version: 1,
           build_id: b.external_build_id,
           job_id: j.id,
           instance_id: "i"
         }}
    }

    {:push, [{:binary, resume}, {:binary, spec}], new_state} =
      AgentSocket.handle_in({PB.AgentFrame.encode(hello), [opcode: :binary]}, state)

    assert {:resume, _} = Protocol.decode_server(resume)
    assert {:spec, %{command: "echo x"}} = Protocol.decode_server(spec)
    assert new_state.job_id == j.id
  end

  test "JobSpec source_url reflects the build's persisted source_url", %{token: token} do
    # Insert a fresh build with an explicit source_url; reuse the shared token.
    {:ok, b2} =
      %Build{}
      |> Build.changeset(%{
        external_build_id: Ecto.UUID.generate(),
        runner_token_hash: :crypto.hash(:sha256, token),
        source_url:
          "https://api.harmont.dev/api/v0/internal/builds/#{Ecto.UUID.generate()}/source.tar.gz"
      })
      |> Repo.insert()

    # Give b2 its own job.
    {:ok, j2} =
      %Job{}
      |> Job.changeset(%{build_id: b2.id, step_key: "b", command: "true", state: "assigned"})
      |> Repo.insert()

    {:ok, state} = AgentSocket.init(token: token)

    {:push, [{:binary, _resume}, {:binary, spec}], _new_state} =
      AgentSocket.handle_in(hello_frame(b2, j2), state)

    assert {:spec, decoded} = Protocol.decode_server(spec)
    assert decoded.source_url == b2.source_url
  end

  test "hello with bad token pushes UNAUTHORIZED", %{build: b, job: j} do
    {:ok, state} = AgentSocket.init(token: "wrong")

    hello = %PB.AgentFrame{
      payload:
        {:hello,
         %PB.HelloMsg{
           proto_version: 1,
           build_id: b.external_build_id,
           job_id: j.id,
           instance_id: "i"
         }}
    }

    {:push, {:binary, err}, _} =
      AgentSocket.handle_in({PB.AgentFrame.encode(hello), [opcode: :binary]}, state)

    assert {:error, %{code: :UNAUTHORIZED}} = Protocol.decode_server(err)
  end

  test "heartbeat frame writes last_heartbeat_at AND resets the live Session watchdog", %{
    build: b,
    job: j,
    token: token
  } do
    alias Ecto.Adapters.SQL.Sandbox
    alias Harmont.Engine.Session

    # Share this sandbox connection with the Session gen_statem (a separate pid).
    Sandbox.mode(Repo, {:shared, self()})

    # Resume the job straight into :running with a 150ms watchdog.
    j |> Job.changeset(%{state: "running", started_at: DateTime.utc_now()}) |> Repo.update!()

    {:ok, _pid} =
      :gen_statem.start_link(
        {:via, Registry, {Harmont.Engine.SessionRegistry, j.id}},
        Session,
        [
          job_id: j.id,
          build_id: b.id,
          token: token,
          backend: HeartbeatSilentBackend,
          api_url: "http://api.test",
          heartbeat_deadline_ms: 300
        ],
        []
      )

    {:ok, state} = AgentSocket.init(token: token)
    {:push, _replies, state} = AgentSocket.handle_in(hello_frame(b, j), state)

    hb = frame({:heartbeat, %PB.Heartbeat{ts_unix_ns: System.system_time(:nanosecond)}})

    # Beat every 60ms for ~420ms (> 150ms deadline). The routed beats must keep
    # the Session alive: the job stays "running".
    Enum.reduce(1..7, state, fn _, st ->
      {:ok, st} = AgentSocket.handle_in(hb, st)
      Process.sleep(60)
      st
    end)

    job = Repo.get!(Job, j.id)
    assert job.state == "running"
    assert job.last_heartbeat_at != nil
  end

  # --- helpers --------------------------------------------------------------

  defp frame(payload),
    do: {PB.AgentFrame.encode(%PB.AgentFrame{payload: payload}), [opcode: :binary]}

  defp hello_frame(b, j, opts \\ []) do
    frame(
      {:hello,
       %PB.HelloMsg{
         proto_version: opts[:proto_version] || 1,
         build_id: opts[:build_id] || b.external_build_id,
         job_id: opts[:job_id] || j.id,
         instance_id: "i"
       }}
    )
  end

  # complete a successful Hello and return the post-Hello socket state.
  defp post_hello_state(b, j, token) do
    {:ok, state} = AgentSocket.init(token: token)

    {:push, [{:binary, _}, {:binary, _}], new_state} =
      AgentSocket.handle_in(hello_frame(b, j), state)

    new_state
  end

  test "hello whose job belongs to a DIFFERENT build pushes JOB_NOT_FOUND", %{
    build: b,
    token: token
  } do
    # a second build + a job that lives under IT, but Hello names build b
    {:ok, b2} =
      %Build{}
      |> Build.changeset(%{
        external_build_id: Ecto.UUID.generate(),
        runner_token_hash: :crypto.hash(:sha256, token)
      })
      |> Repo.insert()

    {:ok, foreign_job} =
      %Job{}
      |> Job.changeset(%{build_id: b2.id, step_key: "z", command: "x", state: "assigned"})
      |> Repo.insert()

    {:ok, state} = AgentSocket.init(token: token)

    {:push, {:binary, err}, _} =
      AgentSocket.handle_in(hello_frame(b, foreign_job, job_id: foreign_job.id), state)

    assert {:error, %{code: :JOB_NOT_FOUND}} = Protocol.decode_server(err)
  end

  test "hello for an unknown build pushes JOB_NOT_FOUND", %{job: j, token: token} do
    {:ok, state} = AgentSocket.init(token: token)

    {:push, {:binary, err}, _} =
      AgentSocket.handle_in(
        hello_frame(%Build{external_build_id: Ecto.UUID.generate()}, j),
        state
      )

    assert {:error, %{code: :JOB_NOT_FOUND}} = Protocol.decode_server(err)
  end

  test "hello below the required proto version pushes PROTO_INCOMPATIBLE", %{
    build: b,
    job: j,
    token: token
  } do
    {:ok, state} = AgentSocket.init(token: token)

    {:push, {:binary, err}, _} =
      AgentSocket.handle_in(hello_frame(b, j, proto_version: 0), state)

    assert {:error, %{code: :PROTO_INCOMPATIBLE}} = Protocol.decode_server(err)
  end

  test "a frame BEFORE Hello is ignored (no crash, keeps state)", %{token: token} do
    {:ok, state} = AgentSocket.init(token: token)
    lc = {:log, %PB.LogChunk{seq: 1, ts_unix_ns: 1, stream: :STDOUT, data: "early"}}
    assert {:ok, ^state} = AgentSocket.handle_in(frame(lc), state)
  end

  test "handle_info(:cancel) after Hello pushes a CancelMsg", %{build: b, job: j, token: token} do
    state = post_hello_state(b, j, token)

    {:push, {:binary, bin}, _} = AgentSocket.handle_info(:cancel, state)
    assert {:cancel, %PB.CancelMsg{}} = Protocol.decode_server(bin)
  end

  test "a :bye frame after Hello stops the socket normally", %{build: b, job: j, token: token} do
    state = post_hello_state(b, j, token)
    bye = {:bye, %PB.ByeMsg{}}
    assert {:stop, :normal, ^state} = AgentSocket.handle_in(frame(bye), state)
  end

  test "a :state frame after Hello routes to the Session and keeps state", %{
    build: b,
    job: j,
    token: token
  } do
    state = post_hello_state(b, j, token)
    # No live Session for this job -> Session.agent_event is a safe no-op cast.
    sm = {:state, %PB.StateMsg{transition: :JOB_REPORTED_PASSED, exit_code: 0}}
    assert {:ok, ^state} = AgentSocket.handle_in(frame(sm), state)
  end

  @tag capture_log: true
  test "an UNKNOWN :state transition after Hello logs and keeps state", %{
    build: b,
    job: j,
    token: token
  } do
    state = post_hello_state(b, j, token)
    sm = {:state, %PB.StateMsg{transition: :UNSPECIFIED, exit_code: 0}}
    assert {:ok, ^state} = AgentSocket.handle_in(frame(sm), state)
  end

  test "a text frame is ignored", %{token: token} do
    {:ok, state} = AgentSocket.init(token: token)
    assert {:ok, ^state} = AgentSocket.handle_in({"hi", [opcode: :text]}, state)
  end
end
