defmodule Harmont.DrainTest do
  @moduledoc """
  Unit coverage for the graceful-drain state machine. `request_drain/1` injects
  both the grace window (`grace_ms`) and the terminal `stop_fun`, so these tests
  never actually halt the VM — the default `&System.stop/0` is never invoked
  here.

  `draining?/0` is backed by a global `:persistent_term`, so each test erases it
  on exit and the suite runs `async: false`.
  """
  use ExUnit.Case, async: false

  alias Harmont.Drain

  setup do
    on_exit(&Drain.reset/0)
    Drain.reset()
    :ok
  end

  test "draining?/0 is false initially" do
    refute Drain.draining?()
  end

  test "request_drain flips draining? and eventually calls the stop fun" do
    test_pid = self()

    assert :ok = Drain.request_drain(grace_ms: 0, stop_fun: fn -> send(test_pid, :stopped) end)
    assert Drain.draining?()
    assert_receive :stopped, 1_000
  end

  test "a second request_drain while draining is a no-op (stop fun called once)" do
    test_pid = self()

    Drain.request_drain(grace_ms: 50, stop_fun: fn -> send(test_pid, :stopped) end)
    # Second call must NOT schedule another stop, even with its own stop_fun.
    Drain.request_drain(grace_ms: 0, stop_fun: fn -> send(test_pid, :stopped_again) end)

    assert Drain.draining?()
    assert_receive :stopped, 1_000
    refute_receive :stopped_again, 200
  end
end
