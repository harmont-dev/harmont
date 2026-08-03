defmodule Harmont.Drain do
  @moduledoc """
  Graceful-shutdown drain state + sequence for the single Harmont node.

  On SIGTERM (`Harmont.SignalHandler`) we `request_drain/1`, which:

    1. flips the global `draining?/0` flag so `/healthz` starts returning 503 —
       the GCE LB health check fails and the LB stops routing new traffic to
       this backend;
    2. in a SEPARATE process, sleeps `grace_ms` (default `:drain_grace_ms`,
       ~20s — long enough for the LB to notice the failing health check and
       de-register the backend);
    3. calls `stop_fun` (default `&System.stop/0`), which walks the supervision
       tree down in reverse start order: the Endpoint + gRPC listeners stop
       accepting first, the repos commit last, and `terminate/2` callbacks run.

  In-flight builds that were cut are recovered on restart by the existing Oban
  reconcile backstop; this drain only avoids abrupt connection cuts and
  mid-write corruption.

  The flag lives in `:persistent_term` (global, fast reads on the hot `/healthz`
  path). `request_drain/1` is idempotent: a second call while already draining
  is a no-op, so we never schedule two stops.

  Both `grace_ms` and `stop_fun` are injectable so tests never halt the VM.
  """

  require Logger

  @key {__MODULE__, :draining?}

  @doc "Whether a drain is in progress. Read on every `/healthz` request."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@key, false)

  @doc """
  Begin draining. Idempotent: a no-op if already draining.

  Options:

    * `:grace_ms` — milliseconds to wait after flipping readiness before calling
      `stop_fun`. Defaults to `config :harmont_core, :drain_grace_ms`.
    * `:stop_fun` — zero-arity terminal function. Defaults to `&System.stop/0`.
  """
  @spec request_drain(keyword()) :: :ok
  def request_drain(opts \\ []) do
    # Atomic flip-if-unset. `:persistent_term` has no CAS, but the BEAM is
    # single-threaded per scheduler reduction here and SIGTERM delivery is rare;
    # the second-call guard reads the flag we just set. The SignalHandler is the
    # only real caller, serialized through `:erl_signal_server`.
    if draining?() do
      :ok
    else
      :persistent_term.put(@key, true)

      grace_ms = Keyword.get(opts, :grace_ms, grace_ms())
      stop_fun = Keyword.get(opts, :stop_fun, stop_fun())

      Logger.info(
        "drain requested — readiness flipped to draining; LB will de-register in #{grace_ms}ms"
      )

      # Separate process so the caller (a gen_event handler) returns promptly and
      # the sleep doesn't block signal delivery.
      spawn(fn ->
        Process.sleep(grace_ms)
        Logger.info("drain grace elapsed — stopping the node")
        stop_fun.()
      end)

      :ok
    end
  end

  @doc false
  # Test-only: clear the global drain flag so it doesn't leak between tests.
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase(@key)
    :ok
  end

  defp grace_ms, do: Application.get_env(:harmont_core, :drain_grace_ms, 20_000)
  defp stop_fun, do: Application.get_env(:harmont_core, :drain_stop_fun, &System.stop/0)
end
