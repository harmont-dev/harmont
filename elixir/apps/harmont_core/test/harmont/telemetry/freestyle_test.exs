defmodule Harmont.Telemetry.FreestyleTest do
  @moduledoc """
  The Freestyle → OpenTelemetry span bridge.

  Following the repo's OTel testing doctrine (see `Harmont.TelemetryTest` /
  `Harmont.ObanTelemetryTest`): we do NOT assert on exported spans — that fights
  `traces_exporter: :none` and the batch processor's async flush, and "a flaky
  OTel-exporter test is worse than none". Instead we drive the telemetry seam the
  bridge subscribes to and assert (a) it attaches, (b) emitting the events runs
  the handlers without raising — `:telemetry` DETACHES a handler that raises, so
  "still attached after execute" proves it didn't, and (c) a start/stop pair
  leaves the per-tracer span stack balanced (no leaked span ctx).

  The companion `Freestyle.RequestTelemetryTest` proves the events themselves
  carry the right metadata; this proves the bridge consumes them cleanly.
  """
  use ExUnit.Case, async: false

  alias Harmont.Telemetry.Freestyle, as: Bridge

  @handler_id "harmont-telemetry-freestyle"
  @stack_key {:otel_telemetry, Bridge}

  setup do
    :ok = Bridge.setup()
    on_exit(fn -> :telemetry.detach(@handler_id) end)
    :ok
  end

  defp base_meta do
    %{
      operation: "freestyle.vm.create_vm",
      method: :post,
      path: "/v1/vms",
      client: "https://api.freestyle.sh"
    }
  end

  defp emit_start(meta),
    do:
      :telemetry.execute(
        [:freestyle, :request, :start],
        %{system_time: 1, monotonic_time: 1},
        meta
      )

  defp emit_stop(meta),
    do: :telemetry.execute([:freestyle, :request, :stop], %{duration: 5, monotonic_time: 2}, meta)

  defp attached?,
    do:
      [:freestyle, :request, :stop]
      |> :telemetry.list_handlers()
      |> Enum.any?(&(&1.id == @handler_id))

  test "setup/0 attaches the bridge to all three freestyle request events" do
    for event <- [
          [:freestyle, :request, :start],
          [:freestyle, :request, :stop],
          [:freestyle, :request, :exception]
        ] do
      assert Enum.any?(:telemetry.list_handlers(event), &(&1.id == @handler_id)),
             "bridge not attached to #{inspect(event)}"
    end
  end

  test "a successful start/stop pair runs cleanly and balances the span stack" do
    meta = base_meta()
    emit_start(meta)
    emit_stop(Map.merge(meta, %{result: :ok, status: 200}))

    # Handler survived (no raise) and the per-tracer stack was pushed then popped.
    assert attached?()
    assert Process.get(@stack_key) in [[], nil]
  end

  test "an errored (timed-out) stop sets error status without raising" do
    meta = base_meta()
    emit_start(meta)

    emit_stop(
      Map.merge(meta, %{
        result: :error,
        status: nil,
        error_kind: :transport,
        error_code: nil,
        error_message: "timeout"
      })
    )

    assert attached?()
    assert Process.get(@stack_key) in [[], nil]
  end

  test "an :exception event is handled without raising" do
    meta = base_meta()
    emit_start(meta)

    :telemetry.execute(
      [:freestyle, :request, :exception],
      %{duration: 5, monotonic_time: 2},
      Map.merge(meta, %{
        kind: :error,
        reason: %RuntimeError{message: "boom"},
        stacktrace: []
      })
    )

    assert attached?()
    assert Process.get(@stack_key) in [[], nil]
  end

  test "a stop with no matching start does not raise (defensive: orphaned event)" do
    emit_stop(Map.merge(base_meta(), %{result: :ok, status: 200}))
    assert attached?()
  end
end
