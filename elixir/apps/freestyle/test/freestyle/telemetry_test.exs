defmodule Freestyle.TelemetryTest do
  use ExUnit.Case, async: true
  alias Freestyle.Telemetry

  setup do
    ref = make_ref()
    handler = "test-#{inspect(ref)}"

    :telemetry.attach_many(
      handler,
      [
        [:freestyle, :request, :start],
        [:freestyle, :request, :stop],
        [:freestyle, :request, :exception],
        [:freestyle, :request, :retry]
      ],
      fn event, measurements, meta, _ ->
        send(self(), {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "span/2 emits start and stop with operation metadata" do
    meta = %{operation: "freestyle.vm.list_vms", method: :get, path: "/v1/vms"}
    result = Telemetry.span(meta, fn -> {:ok, :done} end)

    assert result == {:ok, :done}
    assert_received {:telemetry, [:freestyle, :request, :start], %{system_time: _}, ^meta}
    assert_received {:telemetry, [:freestyle, :request, :stop], %{duration: _}, stop_meta}
    assert stop_meta.operation == "freestyle.vm.list_vms"
  end

  test "span/2 emits an exception event when the function raises" do
    assert_raise RuntimeError, fn ->
      Telemetry.span(%{operation: "x"}, fn -> raise "boom" end)
    end

    assert_received {:telemetry, [:freestyle, :request, :exception], _, meta}
    assert meta.kind == :error
  end

  test "span/2 emits an exception event on a throw and re-propagates it" do
    assert catch_throw(Telemetry.span(%{operation: "x"}, fn -> throw(:boom) end)) == :boom
    assert_received {:telemetry, [:freestyle, :request, :exception], %{duration: _}, meta}
    assert meta.kind == :throw
    assert meta.reason == :boom
  end

  test "span/2 enriches stop metadata for an error result" do
    err = %Freestyle.Error{kind: :api, status: 404, code: :not_found, message: "gone"}
    Telemetry.span(%{operation: "x"}, fn -> {:error, err} end)
    assert_received {:telemetry, [:freestyle, :request, :stop], %{duration: _}, meta}
    assert meta.result == :error
    assert meta.status == 404
    assert meta.error_code == "not_found"
  end

  test "retry/2 emits a retry event" do
    Telemetry.retry(%{operation: "freestyle.vm.create_vm"},
      attempt: 1,
      delay: 250,
      reason: "http_503"
    )

    assert_received {:telemetry, [:freestyle, :request, :retry], %{delay: 250}, meta}
    assert meta.attempt == 1
    assert meta.reason == "http_503"
  end
end
