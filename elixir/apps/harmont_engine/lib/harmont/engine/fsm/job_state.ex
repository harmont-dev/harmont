defmodule Harmont.Engine.Fsm.JobState do
  @moduledoc """
  Pure job state machine.
  Illegal (state, event) pairs return :error and MUST be dropped by callers,
  never crash — this is what makes concurrent "fire-forward" transitions safe.
  """

  @type t ::
          :pending
          | :scheduled
          | :assigned
          | :running
          | :passed
          | :failed
          | :skipped
          | :canceling
          | :canceled
          | :timing_out
          | :timed_out

  @type event ::
          :ready_to_schedule
          | :assigned_to_sandbox
          | :started
          | :cache_hit
          | :reported_passed
          | :reported_failed
          | :timeout_expired
          | :build_timeout
          | :cancel_requested
          | :sandbox_lost

  @terminal ~w(passed failed skipped canceled timed_out)a

  @spec terminal?(t()) :: boolean()
  def terminal?(s), do: s in @terminal

  @spec transition(t(), event()) :: {:ok, t()} | :error
  def transition(:pending, :ready_to_schedule), do: {:ok, :scheduled}
  def transition(:pending, :cancel_requested), do: {:ok, :canceled}

  def transition(:scheduled, :assigned_to_sandbox), do: {:ok, :assigned}
  def transition(:scheduled, :cache_hit), do: {:ok, :passed}
  def transition(:scheduled, :cancel_requested), do: {:ok, :canceled}

  def transition(:assigned, :started), do: {:ok, :running}
  def transition(:assigned, :sandbox_lost), do: {:ok, :failed}
  def transition(:assigned, :cancel_requested), do: {:ok, :canceling}

  def transition(:running, :reported_passed), do: {:ok, :passed}
  def transition(:running, :reported_failed), do: {:ok, :failed}
  def transition(:running, :timeout_expired), do: {:ok, :timing_out}
  def transition(:running, :cancel_requested), do: {:ok, :canceling}
  def transition(:running, :sandbox_lost), do: {:ok, :failed}

  def transition(:timing_out, e)
      when e in ~w(reported_passed reported_failed sandbox_lost)a,
      do: {:ok, :timed_out}

  # :canceling accepts only reported_passed | reported_failed | sandbox_lost
  # (NOT :timeout_expired — per review delta 2026-05-24c)
  def transition(:canceling, e)
      when e in ~w(reported_passed reported_failed sandbox_lost)a,
      do: {:ok, :canceled}

  # Build-level wall-clock budget expired: force any non-terminal job straight
  # to the terminal :timed_out state (the build aggregate then folds to :failed).
  def transition(s, :build_timeout)
      when s in ~w(pending scheduled assigned running timing_out canceling)a,
      do: {:ok, :timed_out}

  def transition(_, _), do: :error

  # Parse a DB-sourced state string without risking ArgumentError inside an Oban
  # worker (String.to_existing_atom raises on an unknown/rolling-deploy state).
  @states ~w(pending scheduled assigned running passed failed skipped canceling canceled timing_out timed_out)

  @spec cast(String.t()) :: {:ok, t()} | :error
  def cast(s) when s in @states, do: {:ok, String.to_existing_atom(s)}
  def cast(_), do: :error

  @doc "Like cast/1 but raises MatchError on an unknown state string."
  @spec cast!(String.t()) :: t()
  def cast!(s) do
    {:ok, atom} = cast(s)
    atom
  end

  @doc "Map an agent StateMsg.Transition enum atom to an engine event."
  @spec from_agent_transition(atom()) :: {:ok, event()} | :error
  def from_agent_transition(:JOB_ASSIGNED_TO_SANDBOX), do: {:ok, :assigned_to_sandbox}
  def from_agent_transition(:JOB_STARTED), do: {:ok, :started}
  def from_agent_transition(:JOB_REPORTED_PASSED), do: {:ok, :reported_passed}
  def from_agent_transition(:JOB_REPORTED_FAILED), do: {:ok, :reported_failed}
  def from_agent_transition(:JOB_TIMEOUT_EXPIRED), do: {:ok, :timeout_expired}
  def from_agent_transition(:JOB_SANDBOX_LOST), do: {:ok, :sandbox_lost}
  def from_agent_transition(_), do: :error
end
