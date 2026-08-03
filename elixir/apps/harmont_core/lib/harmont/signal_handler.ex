defmodule Harmont.SignalHandler do
  @moduledoc """
  `:gen_event` handler installed into `:erl_signal_server` at boot, REPLACING the
  default `:erl_signal_handler`. We own SIGTERM so the default's immediate
  `init:stop/0` cannot race our graceful drain.

  On `:sigterm` we call `Harmont.Drain.request_drain/0`: readiness flips, the LB
  de-registers, then `System.stop/0` shuts the tree down cleanly.

  For the other OS signals the runtime forwards (`:sigquit`, `:sigusr1`,
  `:sigterm`'s siblings), we replicate the default handler's minimal behavior:
  `:sigquit` halts the VM (matching `:erl_signal_handler`), everything else is
  ignored. We intentionally do NOT re-implement the default's SIGTERM path.

  Installed via `install/0` (called from `HarmontCore.Application`), so the
  state the default handler returns on swap is passed to `init({[], term})`.
  """

  @behaviour :gen_event

  require Logger

  @doc """
  Arm graceful SIGTERM handling by swapping our handler in for the runtime's
  default `:erl_signal_handler`. Gated by config so the test suite never arms
  it. We swap (rather than add) so the default's immediate `init:stop/0` on
  SIGTERM can't race our drain. A swap failure is logged, not fatal — booting
  without graceful drain beats refusing to boot.
  """
  @spec install() :: :ok
  def install do
    if Application.get_env(:harmont_core, :graceful_shutdown, true) do
      case :gen_event.swap_handler(
             :erl_signal_server,
             {:erl_signal_handler, []},
             {Harmont.SignalHandler, []}
           ) do
        :ok ->
          :ok

        error ->
          Logger.error("failed to install graceful SIGTERM handler: #{inspect(error)}")
          :ok
      end
    end
  end

  @impl true
  def init({_args, _prev_state}), do: {:ok, %{}}

  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_event(:sigterm, state) do
    Logger.info("SIGTERM received — beginning graceful drain")
    Harmont.Drain.request_drain()
    {:ok, state}
  end

  # Match the default `:erl_signal_handler` for the one signal it acts on.
  def handle_event(:sigquit, state) do
    :erlang.halt()
    {:ok, state}
  end

  # SIGHUP/SIGUSR1/SIGUSR2/SIGTSTP/SIGCONT/SIGABRT etc.: the default handler
  # ignores them; so do we.
  def handle_event(_other, state), do: {:ok, state}

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl true
  def handle_info(_info, state), do: {:ok, state}
end
