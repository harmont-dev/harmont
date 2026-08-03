defmodule Harmont.SignalHandlerTest do
  @moduledoc """
  The SIGTERM gen_event handler delegates to `Harmont.Drain.request_drain/0`. We
  drive `handle_event(:sigterm, state)` directly (no real signal, no swap into
  `:erl_signal_server`) and assert the drain flag flips. The injected `stop_fun`
  never halts the VM.
  """
  use ExUnit.Case, async: false

  alias Harmont.Drain
  alias Harmont.SignalHandler

  setup do
    on_exit(&Drain.reset/0)
    Drain.reset()
    :ok
  end

  test "handling :sigterm requests a drain" do
    refute Drain.draining?()
    assert {:ok, _state} = SignalHandler.handle_event(:sigterm, %{})
    assert Drain.draining?()
  end

  test "other signals are a safe no-op" do
    assert {:ok, _state} = SignalHandler.handle_event(:sigusr1, %{})
    refute Drain.draining?()
  end
end
