defmodule Freestyle.Api.CronTest do
  use Freestyle.ApiCase, async: true
  alias Freestyle.Api.Cron
  alias Freestyle.Page
  alias Freestyle.Types.Cron.{CreateScheduleOpts, Schedule, SuccessRate}

  @tag stub: __MODULE__
  test "create_schedule posts and decodes", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/v1/cron/schedules"
        {body, _} = read_json(conn)
        assert body == %{"deploymentId" => "dep-1", "cron" => "0 9 * * *"}
      end,
      200,
      %{"id" => "s1", "cron" => "0 9 * * *", "deploymentId" => "dep-1"}
    )

    opts = %CreateScheduleOpts{deployment_id: "dep-1", cron: "0 9 * * *"}
    assert {:ok, %Schedule{id: "s1", deployment_id: "dep-1"}} = Cron.create_schedule(client, opts)
  end

  @tag stub: __MODULE__
  test "list_schedules decodes a page via `schedules` key", %{client: client, stub: stub} do
    expect_json(stub, fn conn -> assert conn.request_path == "/v1/cron/schedules" end, 200, %{
      "schedules" => [%{"id" => "s1", "cron" => "* * * * *", "deploymentId" => "d"}],
      "total" => 1
    })

    assert {:ok, %Page{items: [%Schedule{id: "s1"}]}} = Cron.list_schedules(client)
  end

  @tag stub: __MODULE__
  test "get_success_rate decodes value/total", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/v1/cron/schedules/s1/metrics/success-rate"
      end,
      200,
      %{"value" => 0.95, "total" => 100}
    )

    assert {:ok, %SuccessRate{value: 0.95, total: 100}} = Cron.get_success_rate(client, "s1")
  end
end
