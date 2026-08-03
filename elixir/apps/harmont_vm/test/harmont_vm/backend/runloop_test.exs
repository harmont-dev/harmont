defmodule HarmontVm.Backend.RunloopTest do
  use ExUnit.Case, async: true

  alias HarmontVm.Backend.Runloop
  alias HarmontVm.Backend.Runloop.Client

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        cpu_count: 2,
        memory_gb: 4.0,
        disk_gb: 20.0,
        name: "job-uuid",
        base_snapshot: nil,
        parent_snapshot: nil
      },
      overrides
    )
  end

  # Build a handle whose client routes through the injected Req.Test stub, so
  # the handle-taking callbacks (exec/snapshot/teardown/await_ready) hit the stub
  # the same way provision/1's own client does.
  defp handle(devbox_id) do
    %{client: Client.new(Application.fetch_env!(:harmont_vm, Runloop)), devbox_id: devbox_id}
  end

  describe "provision/1" do
    test "creates a devbox at the named size matching cpu/memory, and returns a handle when running" do
      Req.Test.stub(RunloopStub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/devboxes"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["name"] == "job-uuid"
        lp = params["launch_parameters"]
        # 2 cpu / 4 GiB → MEDIUM. CUSTOM_SIZE is non-trial-only, so we never send it.
        assert lp["resource_size_request"] == "MEDIUM"
        refute Map.has_key?(lp, "custom_cpu_cores")
        Req.Test.json(conn, %{"id" => "dbx_1", "status" => "running"})
      end)

      assert {:ok, %{devbox_id: "dbx_1"}} = Runloop.provision(spec())
    end

    test "maps cpu/memory to the smallest fitting named size" do
      check = fn overrides, expected ->
        Req.Test.stub(RunloopStub, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["launch_parameters"]["resource_size_request"] == expected
          Req.Test.json(conn, %{"id" => "dbx_x", "status" => "running"})
        end)

        assert {:ok, _} = Runloop.provision(spec(overrides))
      end

      check.(%{cpu_count: 1, memory_gb: 2.0}, "SMALL")
      check.(%{cpu_count: 2, memory_gb: 4.0}, "MEDIUM")
      check.(%{cpu_count: 2, memory_gb: 8.0}, "LARGE")
      check.(%{cpu_count: 4, memory_gb: 16.0}, "X_LARGE")
    end

    test "a configured :resource_size pins the size regardless of cpu/memory" do
      prev = Application.get_env(:harmont_vm, Runloop)
      Application.put_env(:harmont_vm, Runloop, Keyword.put(prev, :resource_size, "X_LARGE"))
      on_exit(fn -> Application.put_env(:harmont_vm, Runloop, prev) end)

      Req.Test.stub(RunloopStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["launch_parameters"]["resource_size_request"] == "X_LARGE"
        Req.Test.json(conn, %{"id" => "dbx_x", "status" => "running"})
      end)

      assert {:ok, _} = Runloop.provision(spec(%{cpu_count: 1, memory_gb: 2.0}))
    end

    test "polls GET until running when create returns provisioning" do
      Req.Test.stub(RunloopStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/devboxes"} ->
            Req.Test.json(conn, %{"id" => "dbx_2", "status" => "provisioning"})

          {"GET", "/v1/devboxes/dbx_2"} ->
            Req.Test.json(conn, %{"id" => "dbx_2", "status" => "running"})
        end
      end)

      assert {:ok, %{devbox_id: "dbx_2"}} = Runloop.provision(spec())
    end

    test "maps a create 500 to {:provision_failed, _}" do
      Req.Test.stub(RunloopStub, fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"message":"boom"}))
      end)

      assert {:error, {:provision_failed, %{code: "http_500", message: "boom"}}} =
               Runloop.provision(spec())
    end

    test "maps a devbox that enters failure to {:provision_failed, _}" do
      Req.Test.stub(RunloopStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/devboxes"} ->
            Req.Test.json(conn, %{"id" => "dbx_3", "status" => "provisioning"})

          {"GET", "/v1/devboxes/dbx_3"} ->
            Req.Test.json(conn, %{"id" => "dbx_3", "status" => "failure"})
        end
      end)

      assert {:error, {:provision_failed, %{code: "devbox_failure"}}} = Runloop.provision(spec())
    end

    test "passes parent_snapshot as snapshot_id when present" do
      Req.Test.stub(RunloopStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["snapshot_id"] == "snp_parent"
        Req.Test.json(conn, %{"id" => "dbx_4", "status" => "running"})
      end)

      assert {:ok, %{devbox_id: "dbx_4"}} =
               Runloop.provision(spec(%{parent_snapshot: "snp_parent"}))
    end
  end

  describe "await_ready/2" do
    test "returns :ok once running" do
      Req.Test.stub(RunloopStub, fn conn ->
        Req.Test.json(conn, %{"id" => "dbx_1", "status" => "running"})
      end)

      assert :ok = Runloop.await_ready(handle("dbx_1"), 5_000)
    end

    test "times out if never running" do
      Req.Test.stub(RunloopStub, fn conn ->
        Req.Test.json(conn, %{"id" => "dbx_1", "status" => "provisioning"})
      end)

      assert {:error, {:provision_failed, %{code: "provision_timeout"}}} =
               Runloop.await_ready(handle("dbx_1"), 0)
    end
  end

  describe "exec/2" do
    test "returns exit_code/stdout/stderr from execute_sync" do
      Req.Test.stub(RunloopStub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/devboxes/dbx_1/execute_sync"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["command"] == "echo hi"

        Req.Test.json(conn, %{
          "devbox_id" => "dbx_1",
          "exit_status" => 0,
          "stdout" => "hi\n",
          "stderr" => ""
        })
      end)

      assert {:ok, %{exit_code: 0, stdout: "hi\n", stderr: ""}} =
               Runloop.exec(handle("dbx_1"), %{command: "echo hi", hard_cap_ms: 5_000})
    end

    test "preserves a nonzero exit status" do
      Req.Test.stub(RunloopStub, fn conn ->
        Req.Test.json(conn, %{"exit_status" => 7, "stdout" => "", "stderr" => "nope"})
      end)

      assert {:ok, %{exit_code: 7, stderr: "nope"}} =
               Runloop.exec(handle("dbx_1"), %{command: "exit 7", hard_cap_ms: 5_000})
    end

    test "maps a 500 to {:exec_failed, _}" do
      Req.Test.stub(RunloopStub, fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"message":"nope"}))
      end)

      assert {:error, {:exec_failed, %{code: "http_500"}}} =
               Runloop.exec(handle("dbx_1"), %{command: "x", hard_cap_ms: 1_000})
    end

    test "a 2xx body without exit_status is an exec failure, not a crash" do
      Req.Test.stub(RunloopStub, fn conn ->
        Req.Test.json(conn, %{"devbox_id" => "dbx_1", "stdout" => "partial"})
      end)

      assert {:error, {:exec_failed, %{code: "missing_exit_status"}}} =
               Runloop.exec(handle("dbx_1"), %{command: "x", hard_cap_ms: 1_000})
    end
  end

  describe "snapshot/1 (async + poll)" do
    test "kicks off snapshot_disk_async, then returns the id once status is complete" do
      Req.Test.stub(RunloopStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/devboxes/dbx_1/snapshot_disk_async"} ->
            Req.Test.json(conn, %{"id" => "snp_1"})

          {"GET", "/v1/devboxes/disk_snapshots/snp_1/status"} ->
            Req.Test.json(conn, %{"status" => "complete"})
        end
      end)

      assert {:ok, "snp_1"} = Runloop.snapshot(handle("dbx_1"))
    end

    test "polls while the snapshot is in progress, then completes" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(RunloopStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/devboxes/dbx_1/snapshot_disk_async"} ->
            Req.Test.json(conn, %{"id" => "snp_1"})

          {"GET", "/v1/devboxes/disk_snapshots/snp_1/status"} ->
            n = Agent.get_and_update(agent, &{&1, &1 + 1})
            Req.Test.json(conn, %{"status" => if(n == 0, do: "in_progress", else: "complete")})
        end
      end)

      assert {:ok, "snp_1"} = Runloop.snapshot(handle("dbx_1"))
      assert Agent.get(agent, & &1) >= 2
    end

    test "a failed snapshot status maps to {:snapshot_failed, _}" do
      Req.Test.stub(RunloopStub, fn conn ->
        case conn.method do
          "POST" -> Req.Test.json(conn, %{"id" => "snp_1"})
          "GET" -> Req.Test.json(conn, %{"status" => "error"})
        end
      end)

      assert {:error, {:snapshot_failed, %{code: "snapshot_error"}}} =
               Runloop.snapshot(handle("dbx_1"))
    end

    test "a 500 on snapshot_disk_async maps to {:snapshot_failed, _}" do
      Req.Test.stub(RunloopStub, fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"message":"snap boom"}))
      end)

      assert {:error, {:snapshot_failed, %{code: "http_500"}}} = Runloop.snapshot(handle("dbx_1"))
    end
  end

  describe "list_snapshots/0" do
    test "returns id + create_time_ms for each disk snapshot" do
      Req.Test.stub(RunloopStub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/devboxes/disk_snapshots"

        Req.Test.json(conn, %{
          "snapshots" => [
            %{"id" => "snp_a", "create_time_ms" => 1_000, "size_bytes" => 5},
            %{"id" => "snp_b", "create_time_ms" => 2_000}
          ]
        })
      end)

      assert {:ok, list} = Runloop.list_snapshots()

      assert list == [
               %{id: "snp_a", create_time_ms: 1_000},
               %{id: "snp_b", create_time_ms: 2_000}
             ]
    end

    test "surfaces an API error" do
      Req.Test.stub(RunloopStub, fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"message":"boom"}))
      end)

      assert {:error, %{code: "http_500"}} = Runloop.list_snapshots()
    end
  end

  describe "delete_snapshot/1 and teardown/1" do
    test "delete_snapshot POSTs the delete path and returns :ok" do
      Req.Test.stub(RunloopStub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/devboxes/disk_snapshots/snp_1/delete"
        Req.Test.json(conn, %{})
      end)

      assert :ok = Runloop.delete_snapshot("snp_1")
    end

    test "delete_snapshot swallows errors (fire-and-forget)" do
      Req.Test.stub(RunloopStub, fn conn ->
        Plug.Conn.send_resp(conn, 404, ~s({"message":"gone"}))
      end)

      assert :ok = Runloop.delete_snapshot("snp_missing")
    end

    test "teardown POSTs shutdown and returns :ok" do
      Req.Test.stub(RunloopStub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/devboxes/dbx_1/shutdown"
        Req.Test.json(conn, %{"id" => "dbx_1", "status" => "shutdown"})
      end)

      assert :ok = Runloop.teardown(handle("dbx_1"))
    end

    test "teardown is idempotent: a 409 already-down still returns :ok" do
      Req.Test.stub(RunloopStub, fn conn ->
        Plug.Conn.send_resp(conn, 409, ~s({"message":"already down"}))
      end)

      assert :ok = Runloop.teardown(handle("dbx_1"))
    end
  end
end
