defmodule Freestyle.Api.ObservabilityTest do
  use Freestyle.ApiCase, async: true
  alias Freestyle.Api.Observability
  alias Freestyle.Types.Observability.{LogQuery, ObsLogEntry}

  @tag stub: __MODULE__
  test "query_logs sends snake_case params and unwraps logs", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/observability/v1/logs"
        assert conn.params["deployment_id"] == "dep-1"
        assert conn.params["start_time"] == "2026-05-24T00:00:00Z"
      end,
      200,
      %{
        "logs" => [%{"timestamp" => "2026-05-24T00:00:01Z", "message" => "hi", "level" => "info"}]
      }
    )

    query = %LogQuery{deployment_id: "dep-1", start_time: "2026-05-24T00:00:00Z"}

    assert {:ok, [%ObsLogEntry{message: "hi", level: "info"}]} =
             Observability.query_logs(client, query)
  end
end
