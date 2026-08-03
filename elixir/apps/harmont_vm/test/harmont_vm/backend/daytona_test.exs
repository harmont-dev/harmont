defmodule HarmontVm.Backend.DaytonaTest do
  use ExUnit.Case, async: true

  alias HarmontVm.Backend.Daytona
  alias HarmontVm.Backend.Daytona.Client

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

  # Build a handle whose client routes through the injected Req.Test stub, so the
  # handle-taking callbacks (exec/snapshot/teardown) hit the stub the same way
  # provision/1's own client does.
  defp handle(sandbox_id) do
    %{client: Client.new(Application.fetch_env!(:harmont_vm, Daytona)), sandbox_id: sandbox_id}
  end

  describe "provision/1 (fresh, no parent) — create-from-snapshot + verify" do
    test "creates a job sandbox from the snapshot, verifies overlay, never forks" do
      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox/" <> rest} ->
            if String.ends_with?(rest, "/fork"),
              do: flunk("no-parent provision must not call fork"),
              else: Req.Test.json(conn, %{"id" => "sb_job", "state" => "creating"})

          {"POST", "/api/sandbox"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            params = Jason.decode!(body)
            assert params["snapshot"] == "test-runner-snapshot"
            assert params["target"] == "experimental"
            assert params["labels"]["harmont"] == "job"
            # Ephemeral lifecycle (autoDeleteInterval == 0) is what unlocks the
            # 30 GiB linux-vm grant; the disk itself is inherited from the snapshot.
            assert params["autoDeleteInterval"] == 0
            # Daytona 400s ("Cannot specify Sandbox resources when using a
            # snapshot") if disk/cpu/memory are sent with a snapshot, and
            # sandboxClass is not a CreateSandbox field. None may appear here.
            refute Map.has_key?(params, "disk")
            refute Map.has_key?(params, "cpu")
            refute Map.has_key?(params, "memory")
            refute Map.has_key?(params, "sandboxClass")
            Req.Test.json(conn, %{"id" => "sb_job", "state" => "creating"})

          {"GET", "/api/sandbox/sb_job"} ->
            Req.Test.json(conn, %{"id" => "sb_job", "state" => "started"})

          {"POST", "/toolbox/sb_job/process/execute"} ->
            Req.Test.json(conn, %{"exitCode" => 0, "result" => ""})

          {"PUT", "/api/sandbox/sb_job/labels"} ->
            # provision/1 re-asserts harmont=job (best-effort) after create.
            Req.Test.json(conn, %{})

          {"GET", "/api/sandbox"} ->
            Req.Test.json(conn, %{"items" => []})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert {:ok, %{sandbox_id: "sb_job"}} = Daytona.provision(spec())
    end

    test "retries past a bad-overlay restore, then a second create succeeds" do
      # First create comes up as the bare base image (overlay probe fails): it is
      # torn down and a second create — which carries the overlay — is handed out.
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox/" <> rest} ->
            if String.ends_with?(rest, "/fork"),
              do: flunk("no-parent provision must not call fork"),
              else: flunk("unexpected per-id POST: #{rest}")

          {"POST", "/api/sandbox"} ->
            n = Agent.get_and_update(agent, &{&1, &1 + 1})
            Req.Test.json(conn, %{"id" => "sb_#{n}", "state" => "creating"})

          {"GET", "/api/sandbox/sb_" <> _} ->
            Req.Test.json(conn, %{"state" => "started"})

          {"POST", "/toolbox/sb_0/process/execute"} ->
            # First restore is base-image-only: the overlay probe fails.
            Req.Test.json(conn, %{"exitCode" => 1, "result" => ""})

          {"POST", "/toolbox/sb_1/process/execute"} ->
            # Second restore carries the overlay.
            Req.Test.json(conn, %{"exitCode" => 0, "result" => ""})

          {"DELETE", "/api/sandbox/sb_0"} ->
            # The bad sandbox is torn down before the retry.
            Req.Test.json(conn, %{})

          {"PUT", "/api/sandbox/sb_1/labels"} ->
            Req.Test.json(conn, %{})
        end
      end)

      assert {:ok, %{sandbox_id: "sb_1"}} = Daytona.provision(spec())
      # Two creates: the rejected restore plus the good one.
      assert Agent.get(agent, & &1) == 2
    end

    test "exhausts all 8 attempts when every restore has a bad overlay" do
      # Every create comes back as a base-image-only restore (overlay probe always
      # fails). All 8 (@create_verify_attempts) sandboxes are torn down and the
      # function returns {:error, {:provision_failed, %{code: "snapshot_overlay_unavailable"}}}.
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox/" <> rest} ->
            if String.ends_with?(rest, "/fork"),
              do: flunk("no-parent provision must not call fork"),
              else: flunk("unexpected per-id POST: #{rest}")

          {"POST", "/api/sandbox"} ->
            n = Agent.get_and_update(agent, &{&1, &1 + 1})
            Req.Test.json(conn, %{"id" => "sb_#{n}", "state" => "creating"})

          {"GET", "/api/sandbox/sb_" <> _} ->
            Req.Test.json(conn, %{"state" => "started"})

          {"POST", "/toolbox/sb_" <> _} ->
            # Every overlay probe fails — overlay is never present.
            Req.Test.json(conn, %{"exitCode" => 1, "result" => ""})

          {"DELETE", "/api/sandbox/sb_" <> _} ->
            # Each bad sandbox is torn down before the next attempt.
            Req.Test.json(conn, %{})
        end
      end)

      assert {:error, {:provision_failed, %{code: "snapshot_overlay_unavailable"}}} =
               Daytona.provision(spec())

      # All 8 attempts were made and exhausted.
      assert Agent.get(agent, & &1) == 8
    end

    test "a persistent transient create 400 exhausts the create-retry budget, then surfaces" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox"} ->
            Agent.update(agent, &(&1 + 1))

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              400,
              Jason.encode!(%{"message" => "Sandbox failed to start: internal error"})
            )

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      # "internal error" is transient: retried across the whole create budget
      # (@create_retry_attempts = 12), surfaced only once exhausted. Orphan cleanup
      # is the SandboxReaper's job, so there is NO inline list/delete here.
      assert {:error, {:provision_failed, %{code: "http_400"}}} = Daytona.provision(spec())
      assert Agent.get(agent, & &1) == 12
    end

    test "retries past a transient create 400, then a later create succeeds" do
      # First create 400s ("internal error"); the create is retried (no inline
      # reap — the failed attempt makes no GET/DELETE) and the second boots cleanly.
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox"} ->
            n = Agent.get_and_update(agent, &{&1, &1 + 1})

            if n == 0 do
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                400,
                Jason.encode!(%{"message" => "Sandbox failed to start: internal error"})
              )
            else
              Req.Test.json(conn, %{"id" => "sb_ok", "state" => "creating"})
            end

          {"GET", "/api/sandbox/sb_ok"} ->
            Req.Test.json(conn, %{"state" => "started"})

          {"POST", "/toolbox/sb_ok/process/execute"} ->
            Req.Test.json(conn, %{"exitCode" => 0, "result" => ""})

          {"PUT", "/api/sandbox/sb_ok/labels"} ->
            Req.Test.json(conn, %{})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert {:ok, %{sandbox_id: "sb_ok"}} = Daytona.provision(spec())
      # Exactly two creates: the transient 400, then the success.
      assert Agent.get(agent, & &1) == 2
    end

    test "each create attempt uses a UNIQUE sandbox name (so a retry can't 409)" do
      # The fix for Daytona's 400-but-leaves-a-`creating`-orphan race: a fixed name
      # would 409 every retry against the undead orphan; a fresh name per attempt
      # can't collide.
      {:ok, names} = Agent.start_link(fn -> [] end)

      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            seen =
              Agent.get_and_update(names, fn acc -> {acc, [Jason.decode!(body)["name"] | acc]} end)

            if seen == [] do
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                400,
                Jason.encode!(%{"message" => "Sandbox failed to start: internal error"})
              )
            else
              Req.Test.json(conn, %{"id" => "sb_ok", "state" => "creating"})
            end

          {"GET", "/api/sandbox/sb_ok"} ->
            Req.Test.json(conn, %{"state" => "started"})

          {"POST", "/toolbox/sb_ok/process/execute"} ->
            Req.Test.json(conn, %{"exitCode" => 0, "result" => ""})

          {"PUT", "/api/sandbox/sb_ok/labels"} ->
            Req.Test.json(conn, %{})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert {:ok, _} = Daytona.provision(spec())
      used = Agent.get(names, & &1)
      assert length(used) == 2
      assert length(Enum.uniq(used)) == 2, "names must differ per attempt, got: #{inspect(used)}"
      # Each name is derived from the job id (spec name "job-uuid") with a suffix.
      assert Enum.all?(used, &String.starts_with?(&1, "job-uuid-"))
    end

    test "maps a create 500 to {:provision_failed, _}" do
      Req.Test.stub(DaytonaStub, fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"message":"boom"}))
      end)

      assert {:error, {:provision_failed, %{code: "http_500"}}} = Daytona.provision(spec())
    end

    test "a sandbox that enters build_failed maps to {:provision_failed, _} (no retry storm)" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox"} ->
            Agent.update(agent, &(&1 + 1))
            Req.Test.json(conn, %{"id" => "sb_bf", "state" => "creating"})

          {"GET", "/api/sandbox/sb_bf"} ->
            Req.Test.json(conn, %{"id" => "sb_bf", "state" => "build_failed"})

          {"DELETE", "/api/sandbox/sb_bf"} ->
            Req.Test.json(conn, %{})
        end
      end)

      assert {:error, {:provision_failed, %{code: "sandbox_build_failed"}}} =
               Daytona.provision(spec())

      # build_failed is not self-healing: surfaced after ONE create, not 8.
      assert Agent.get(agent, & &1) == 1
    end
  end

  describe "provision/1 (fork from parent)" do
    test "POSTs /api/sandbox/{parent}/fork, polls child to started" do
      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"PUT", "/api/sandbox/sb_child/labels"} ->
            Req.Test.json(conn, %{})

          {"POST", "/api/sandbox/sb_parent/fork"} ->
            Req.Test.json(conn, %{"id" => "sb_child", "state" => "creating"})

          {"GET", "/api/sandbox/sb_child"} ->
            Req.Test.json(conn, %{"id" => "sb_child", "state" => "started"})
        end
      end)

      assert {:ok, %{sandbox_id: "sb_child"}} =
               Daytona.provision(spec(%{parent_snapshot: "sb_parent"}))
    end

    test "retries the fork while the parent is transiently mid-fork" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"PUT", "/api/sandbox/sb_child/labels"} ->
            Req.Test.json(conn, %{})

          {"POST", "/api/sandbox/sb_parent/fork"} ->
            n = Agent.get_and_update(agent, &{&1, &1 + 1})

            if n == 0 do
              Plug.Conn.send_resp(
                conn,
                400,
                ~s({"message":"Sandbox must be in started state to fork"})
              )
            else
              Req.Test.json(conn, %{"id" => "sb_child", "state" => "creating"})
            end

          {"GET", "/api/sandbox/sb_child"} ->
            Req.Test.json(conn, %{"id" => "sb_child", "state" => "started"})
        end
      end)

      assert {:ok, %{sandbox_id: "sb_child"}} =
               Daytona.provision(spec(%{parent_snapshot: "sb_parent"}))

      assert Agent.get(agent, & &1) >= 2
    end

    test "retries the fork on an optimistic-concurrency conflict" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"PUT", "/api/sandbox/sb_child/labels"} ->
            Req.Test.json(conn, %{})

          {"POST", "/api/sandbox/sb_parent/fork"} ->
            n = Agent.get_and_update(agent, &{&1, &1 + 1})

            if n == 0 do
              Plug.Conn.send_resp(
                conn,
                409,
                ~s({"message":"Sandbox was modified by another operation"})
              )
            else
              Req.Test.json(conn, %{"id" => "sb_child", "state" => "creating"})
            end

          {"GET", "/api/sandbox/sb_child"} ->
            Req.Test.json(conn, %{"id" => "sb_child", "state" => "started"})
        end
      end)

      assert {:ok, %{sandbox_id: "sb_child"}} =
               Daytona.provision(spec(%{parent_snapshot: "sb_parent"}))

      assert Agent.get(agent, & &1) >= 2
    end

    test "retries the fork on Daytona's concurrent-fork 'feature flags' error" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(DaytonaStub, fn conn ->
        case {conn.method, conn.request_path} do
          {"PUT", "/api/sandbox/sb_child/labels"} ->
            Req.Test.json(conn, %{})

          {"POST", "/api/sandbox/sb_parent/fork"} ->
            n = Agent.get_and_update(agent, &{&1, &1 + 1})

            if n == 0 do
              Plug.Conn.send_resp(
                conn,
                400,
                ~s({"message":"Required feature flags are not enabled"})
              )
            else
              Req.Test.json(conn, %{"id" => "sb_child", "state" => "creating"})
            end

          {"GET", "/api/sandbox/sb_child"} ->
            Req.Test.json(conn, %{"id" => "sb_child", "state" => "started"})
        end
      end)

      assert {:ok, %{sandbox_id: "sb_child"}} =
               Daytona.provision(spec(%{parent_snapshot: "sb_parent"}))

      assert Agent.get(agent, & &1) >= 2
    end
  end

  describe "exec/2" do
    test "POSTs to the toolbox process/execute and maps exitCode/result" do
      Req.Test.stub(DaytonaStub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/toolbox/sb_1/process/execute"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["command"] == "echo hi"
        Req.Test.json(conn, %{"exitCode" => 0, "result" => "hi\n"})
      end)

      assert {:ok, %{exit_code: 0, stdout: "hi\n", stderr: ""}} =
               Daytona.exec(handle("sb_1"), %{command: "echo hi", hard_cap_ms: 5_000})
    end

    test "preserves a nonzero exit code" do
      Req.Test.stub(DaytonaStub, fn conn ->
        Req.Test.json(conn, %{"exitCode" => 7, "result" => "boom"})
      end)

      assert {:ok, %{exit_code: 7, stdout: "boom", stderr: ""}} =
               Daytona.exec(handle("sb_1"), %{command: "exit 7", hard_cap_ms: 5_000})
    end

    test "maps a 500 to {:exec_failed, _}" do
      Req.Test.stub(DaytonaStub, fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"message":"nope"}))
      end)

      assert {:error, {:exec_failed, %{code: "http_500"}}} =
               Daytona.exec(handle("sb_1"), %{command: "x", hard_cap_ms: 1_000})
    end
  end

  describe "snapshot/1" do
    test "returns the live sandbox id with no HTTP call" do
      # No stub set: any HTTP call would raise, proving snapshot/1 hits no network.
      assert {:ok, "sb_self"} = Daytona.snapshot(handle("sb_self"))
    end
  end

  describe "delete_snapshot/1 and teardown/1" do
    test "delete_snapshot DELETEs the sandbox and returns :ok" do
      Req.Test.stub(DaytonaStub, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/api/sandbox/sb_x"
        Req.Test.json(conn, %{})
      end)

      assert :ok = Daytona.delete_snapshot("sb_x")
    end

    test "delete_snapshot swallows errors (a parent with live children 400s)" do
      Req.Test.stub(DaytonaStub, fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"message":"has children"}))
      end)

      assert :ok = Daytona.delete_snapshot("sb_x")
    end

    test "teardown DELETEs the sandbox and returns :ok" do
      Req.Test.stub(DaytonaStub, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/api/sandbox/sb_1"
        Req.Test.json(conn, %{})
      end)

      assert :ok = Daytona.teardown(handle("sb_1"))
    end
  end

  describe "list_managed_sandboxes/0" do
    test "returns all harmont-owned sandboxes with kinds" do
      Req.Test.stub(DaytonaStub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/sandbox"

        Req.Test.json(conn, %{
          "items" => [
            %{
              "id" => "j1",
              "labels" => %{"harmont" => "job"},
              "createdAt" => "2026-06-08T00:00:00Z"
            },
            %{
              "id" => "t1",
              "labels" => %{"harmont" => "template", "harmont_snapshot" => "snap-current"},
              "createdAt" => "2026-06-08T00:00:00Z"
            },
            %{
              "id" => "p1",
              "labels" => %{
                "harmont" => "template-pending",
                "harmont_snapshot" => "snap-old"
              },
              "createdAt" => "2026-06-08T00:00:00Z"
            },
            %{
              "id" => "x1",
              "labels" => %{"someone_else" => "yes"},
              "createdAt" => "2026-06-08T00:00:00Z"
            }
          ]
        })
      end)

      assert {:ok, list} = Daytona.list_managed_sandboxes()
      by_id = Map.new(list, &{&1.id, &1})

      assert by_id["j1"].kind == :job
      assert by_id["t1"].kind == :template
      assert by_id["t1"].snapshot_label == "snap-current"
      assert by_id["p1"].kind == :template_pending
      refute Map.has_key?(by_id, "x1")
      assert map_size(by_id) == 3
    end

    test "walks every page when the list spans more than one page" do
      # Daytona caps the sandbox list at 100 items per page; a leaked sandbox
      # past the first page must still be reaped. Page 1 returns a FULL 100-item
      # page (so the walk must continue), page 2 returns a short page (the last).
      page1 = for n <- 1..100, do: %{"id" => "j#{n}", "labels" => %{"harmont" => "job"}}
      page2 = [%{"id" => "j101", "labels" => %{"harmont" => "job"}}]

      Req.Test.stub(DaytonaStub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/sandbox"
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["page"] do
          "1" -> Req.Test.json(conn, %{"items" => page1})
          "2" -> Req.Test.json(conn, %{"items" => page2})
        end
      end)

      assert {:ok, list} = Daytona.list_managed_sandboxes()
      ids = MapSet.new(list, & &1.id)
      assert MapSet.size(ids) == 101
      assert MapSet.member?(ids, "j1")
      assert MapSet.member?(ids, "j101")
    end

    test "surfaces an API error" do
      Req.Test.stub(DaytonaStub, fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"message":"boom"}))
      end)

      assert {:error, %{code: "http_500"}} = Daytona.list_managed_sandboxes()
    end

    test "surfaces each sandbox's state alongside id/kind/age" do
      Req.Test.stub(DaytonaStub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/sandbox"

        Req.Test.json(conn, %{
          "items" => [
            %{
              "id" => "sb1",
              "state" => "error",
              "createdAt" => "2026-06-01T00:00:00Z",
              "labels" => %{"harmont" => "job"}
            }
          ]
        })
      end)

      assert {:ok, [sb]} = Daytona.list_managed_sandboxes()
      assert sb.id == "sb1"
      assert sb.state == "error"
    end
  end

  describe "fork_source_is_live_vm?/0" do
    test "returns true (the fork source is the live VM)" do
      assert Daytona.fork_source_is_live_vm?() == true
    end
  end
end
