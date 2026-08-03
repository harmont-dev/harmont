defmodule Harmont.Agent.Bridge do
  @moduledoc """
  Applies one upstream agent frame to engine state:
    :log       -> Logs.Store.append (idempotent) + fan-out
    :heartbeat -> jobs.last_heartbeat_at = now
    other      -> no-op

  NOTE: there is NO :state clause here. Per REVISION 2026-05-24c, the Session
  gen_statem owns live state transitions (it arms the wall-clock on :started and
  calls Advance on terminal). AgentSocket routes :state frames to
  Session.agent_event/2, NOT to the Bridge. Applying state in both places would
  drop the wall-clock arm. The Bridge handles logs + heartbeat ONLY.
  """
  import Ecto.Query
  require Logger
  alias Harmont.Builds.Job
  alias Harmont.Logs.Store

  @spec apply_frame(Ecto.UUID.t(), {atom(), struct()}, String.t()) :: :ok
  def apply_frame(job_id, {:log, lc}, instance_id) do
    {:ok, _max} =
      Store.append(job_id, %{
        seq: lc.seq,
        stream_kind: stream_kind(lc.stream),
        content: lc.data,
        ts_unix_ns: lc.ts_unix_ns,
        instance_id: instance_id
      })

    :ok
  end

  def apply_frame(job_id, {:heartbeat, _hb}, _instance_id) do
    # soft-match: row may be gone (build purged)
    {_n, _} =
      Harmont.Repo.update_all(
        from(j in Job, where: j.id == ^job_id),
        set: [last_heartbeat_at: DateTime.utc_now()]
      )

    :ok
  end

  def apply_frame(_job_id, _frame, _instance_id), do: :ok

  defp stream_kind(:STDOUT), do: 0
  defp stream_kind(:STDERR), do: 1
  defp stream_kind(:META), do: 2
  defp stream_kind(_), do: 0
end
