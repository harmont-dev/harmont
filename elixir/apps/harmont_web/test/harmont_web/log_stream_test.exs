defmodule HarmontWeb.LogStreamTest do
  use Harmont.DataCase, async: false
  import Plug.Test
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Repo
  alias HarmontWeb.{LogStream, LogToken}

  defp mint(build_uuid, exp \\ System.system_time(:second) + 3600) do
    secret = LogToken.secret()
    p = Jason.encode!(%{"build" => build_uuid, "exp" => exp}) |> Base.url_encode64(padding: false)
    mac = :crypto.mac(:hmac, :sha256, secret, p) |> Base.url_encode64(padding: false)
    p <> "." <> mac
  end

  defp call(conn, job_id) do
    conn |> Plug.Conn.fetch_query_params() |> LogStream.call(job_id)
  end

  describe "sse_event/2" do
    test "frames a chunk as id/event/data lines terminated by a blank line" do
      chunk = %{seq: 7, stream_kind: 0, content: "hello\n", ts_unix_ns: 42}
      frame = LogStream.sse_event("chunk", chunk) |> IO.iodata_to_binary()

      assert [id_line, event_line, data_line, "", ""] = String.split(frame, "\n")
      assert id_line == "id: 7"
      assert event_line == "event: chunk"
      assert "data: " <> json = data_line

      assert Jason.decode!(json) == %{
               "seq" => 7,
               "stream_kind" => 0,
               "content" => "hello\n",
               "ts" => 42
             }
    end

    test "renders missing stream_kind as 0 and stringifies content" do
      frame =
        LogStream.sse_event("chunk", %{seq: 1, content: "x", ts_unix_ns: nil})
        |> IO.iodata_to_binary()

      "data: " <> json = frame |> String.split("\n") |> Enum.at(2)
      decoded = Jason.decode!(json)
      assert decoded["stream_kind"] == 0
      assert decoded["content"] == "x"
      assert decoded["ts"] == nil
    end
  end

  # Resume-cursor parsing (`Last-Event-ID` header / `last_event_id` query
  # param) is no longer exposed as a public function; it's exercised
  # end-to-end by the integration suite's `Last-Event-ID` resume test.

  describe "call/2 authorization" do
    setup do
      {:ok, b} =
        %Build{}
        |> Build.changeset(%{external_build_id: Ecto.UUID.generate()})
        |> Repo.insert()

      {:ok, j} =
        %Job{}
        |> Job.changeset(%{build_id: b.id, step_key: "a", command: "x", state: "running"})
        |> Repo.insert()

      %{build: b, job: j}
    end

    test "returns 401 with a JSON error body when no token is supplied", %{job: j} do
      conn = call(conn(:get, "/v0/jobs/#{j.id}/logs"), j.id)
      assert conn.status == 401
      refute "text/event-stream" in Plug.Conn.get_resp_header(conn, "content-type")
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["code"])
      assert is_binary(body["message"])
    end

    test "returns 401 when the token fails verification", %{job: j} do
      conn = call(conn(:get, "/v0/jobs/#{j.id}/logs?token=garbage.sig"), j.id)
      assert conn.status == 401
      refute "text/event-stream" in Plug.Conn.get_resp_header(conn, "content-type")
    end

    test "returns 403 when the token is valid but the job is not in that build", %{job: j} do
      token = mint(Ecto.UUID.generate())
      conn = call(conn(:get, "/v0/jobs/#{j.id}/logs?token=#{token}"), j.id)
      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["code"])
    end
  end
end
