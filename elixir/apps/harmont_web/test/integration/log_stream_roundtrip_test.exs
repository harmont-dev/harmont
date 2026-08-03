defmodule Harmont.Integration.LogStreamRoundtripTest do
  @moduledoc """
  End-to-end SSE log stream integration test over REAL HTTP.

  Proves the full path any HTTP client (browser EventSource, hm CLI) uses:

  1. Token-authenticated GET /v0/jobs/:job_id/logs?token=<t> → 200 +
     `text/event-stream`, with a `history` event replaying the seeded chunk.
  2. Store.append (which broadcasts) a new chunk → a live `chunk` SSE event
     arrives carrying the right `id:`/seq.
  3. Reconnect with `Last-Event-ID: <seq>` → history replay starts AFTER that
     seq (no duplicate of the already-seen chunk).
  4. Bad token → 401 (no event-stream).

  We drive the stream with :gun over plain HTTP/1.1 (no WS upgrade): an SSE
  response is just a long-lived chunked GET, so each `{:gun_data, ...}` frame
  carries SSE bytes we parse into events. This mirrors the agent roundtrip
  harness (ephemeral Bandit listener on a loopback port, shared Ecto sandbox).

  Run: mix test --only integration
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Logs.{LogChunk, Store}
  alias Harmont.Repo
  import Ecto.Query

  # Distinct from agent_roundtrip_test (4897) and the dev server (4000).
  @port 4_901

  setup_all do
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

  setup do
    pid = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    {:ok, build} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate()})
      |> Repo.insert()

    {:ok, job} =
      %Job{}
      |> Job.changeset(%{
        build_id: build.id,
        step_key: "log-stream-roundtrip",
        command: "echo log-test",
        state: "running"
      })
      |> Repo.insert()

    {:ok, _} =
      Store.append(job.id, %{seq: 1, stream_kind: 0, content: "history-line\n", ts_unix_ns: 1})

    on_exit(fn ->
      Repo.delete_all(from(c in LogChunk, where: c.job_id == ^job.id))
      Repo.delete_all(from(j in Job, where: j.id == ^job.id))
      Repo.delete_all(from(b in Build, where: b.id == ^build.id))
    end)

    %{build: build, job: job}
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp mint_token(build_uuid, secret \\ HarmontWeb.LogToken.secret()) do
    exp = System.system_time(:second) + 3600
    p = Jason.encode!(%{"build" => build_uuid, "exp" => exp}) |> Base.url_encode64(padding: false)
    mac = :crypto.mac(:hmac, :sha256, secret, p) |> Base.url_encode64(padding: false)
    p <> "." <> mac
  end

  # Open a gun connection and issue a GET. Returns {conn, stream_ref}.
  defp sse_get(path, headers \\ []) do
    {:ok, conn} = :gun.open(~c"127.0.0.1", @port, %{protocols: [:http], retry: 0})
    {:ok, :http} = :gun.await_up(conn, 5_000)
    stream_ref = :gun.get(conn, String.to_charlist(path), headers)
    {conn, stream_ref}
  end

  # Await the response head; returns {status, headers}.
  defp await_headers(conn, stream_ref, timeout \\ 5_000) do
    receive do
      {:gun_response, ^conn, ^stream_ref, :nofin, status, headers} ->
        {status, headers}

      {:gun_response, ^conn, ^stream_ref, :fin, status, headers} ->
        {status, headers}
    after
      timeout -> raise "timeout awaiting response head"
    end
  end

  # Accumulate response body bytes until `matcher.(buffer)` returns a value, or
  # timeout. Returns {value, buffer}.
  defp await_body(conn, stream_ref, matcher, timeout \\ 5_000, buffer \\ "") do
    case matcher.(buffer) do
      nil ->
        receive do
          {:gun_data, ^conn, ^stream_ref, _, data} ->
            await_body(conn, stream_ref, matcher, timeout, buffer <> data)
        after
          timeout -> raise "timeout awaiting body match; buffer so far: #{inspect(buffer)}"
        end

      value ->
        {value, buffer}
    end
  end

  # Parse the data payload of the first SSE event named `name` from a buffer of
  # accumulated SSE text. Returns the decoded JSON map, or nil if not yet seen.
  defp find_event(buffer, name) do
    buffer
    |> String.split("\n\n")
    |> Enum.find_value(fn block -> event_data(block, name) end)
  end

  defp event_data(block, name) do
    lines = String.split(block, "\n")

    with true <- Enum.any?(lines, &(&1 == "event: #{name}")),
         data <-
           lines
           |> Enum.filter(&String.starts_with?(&1, "data: "))
           |> Enum.map_join("\n", &String.replace_prefix(&1, "data: ", "")),
         false <- data == "" do
      Jason.decode!(data)
    else
      _ -> nil
    end
  end

  # ── tests ──────────────────────────────────────────────────────────────────

  test "valid token → 200 text/event-stream, history replay, then live chunk", %{
    build: build,
    job: job
  } do
    token = mint_token(build.external_build_id)
    {conn, ref} = sse_get("/v0/jobs/#{job.id}/logs?token=#{URI.encode_www_form(token)}")
    on_exit(fn -> :gun.shutdown(conn) end)

    {status, headers} = await_headers(conn, ref)
    assert status == 200
    ctype = :proplists.get_value("content-type", headers)
    assert ctype != :undefined and String.starts_with?(to_string(ctype), "text/event-stream")

    {history, _} = await_body(conn, ref, &find_event(&1, "history"))
    chunks = history["chunks"]
    assert is_list(chunks)
    seeded = Enum.find(chunks, &(&1["seq"] == 1))
    assert seeded["content"] == "history-line\n"

    # Append + broadcast a live chunk; expect a `chunk` SSE event with id/seq 2.
    {:ok, _} =
      Store.append(job.id, %{seq: 2, stream_kind: 0, content: "live-line\n", ts_unix_ns: 2})

    {live, buffer} = await_body(conn, ref, &find_event(&1, "chunk"))
    assert live["seq"] == 2
    assert live["content"] == "live-line\n"
    # The framed event must carry an `id:` line equal to the seq.
    assert buffer =~ "id: 2\nevent: chunk"
  end

  test "Last-Event-ID resume replays only chunks after the given seq", %{
    build: build,
    job: job
  } do
    # Seed a second chunk so there is something both before and after the cursor.
    {:ok, _} =
      Store.append(job.id, %{seq: 2, stream_kind: 0, content: "second\n", ts_unix_ns: 2})

    token = mint_token(build.external_build_id)

    {conn, ref} =
      sse_get(
        "/v0/jobs/#{job.id}/logs?token=#{URI.encode_www_form(token)}",
        [{"last-event-id", "1"}]
      )

    on_exit(fn -> :gun.shutdown(conn) end)

    {status, _} = await_headers(conn, ref)
    assert status == 200

    {history, _} = await_body(conn, ref, &find_event(&1, "history"))
    seqs = history["chunks"] |> Enum.map(& &1["seq"])
    # seq 1 was already delivered (Last-Event-ID: 1) → must NOT be replayed.
    refute 1 in seqs
    assert 2 in seqs
  end

  test "bad token → 401, not an event-stream", %{job: job} do
    {conn, ref} = sse_get("/v0/jobs/#{job.id}/logs?token=not.a.valid.token")
    on_exit(fn -> :gun.shutdown(conn) end)

    {status, headers} = await_headers(conn, ref)
    assert status == 401
    ctype = to_string(:proplists.get_value("content-type", headers, ""))
    refute String.starts_with?(ctype, "text/event-stream")
  end
end
