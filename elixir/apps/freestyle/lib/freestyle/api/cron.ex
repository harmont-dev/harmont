defmodule Freestyle.Api.Cron do
  @moduledoc "Cron schedule endpoints (Freestyle-side; not on Harmont's engine path)."

  alias Freestyle.{Client, Error, Page, Pagination, Request, Types}

  alias Freestyle.Types.Cron.{
    CreateScheduleOpts,
    Execution,
    MetricsTimeline,
    Schedule,
    SuccessRate,
    UpdateScheduleOpts
  }

  defp base, do: "/v1/cron/schedules"

  @doc "GET schedules — one page."
  @spec list_schedules(Client.t(), Types.page_params()) ::
          {:ok, Page.t(Schedule.t())} | {:error, Error.t()}
  def list_schedules(client, params \\ %{}) do
    Request.get(
      client,
      base(),
      [limit: Map.get(params, :limit, 50), offset: Map.get(params, :offset, 0)],
      &Page.decode(&1, fn item -> Schedule.decode(item) end),
      "freestyle.cron.list_schedules"
    )
  end

  @doc "Lazy stream over all schedules."
  @spec stream_schedules(Client.t()) :: Enumerable.t()
  def stream_schedules(client), do: Pagination.stream(fn p -> list_schedules(client, p) end)

  @doc "POST a schedule."
  @spec create_schedule(Client.t(), CreateScheduleOpts.t()) ::
          {:ok, Schedule.t()} | {:error, Error.t()}
  def create_schedule(client, %CreateScheduleOpts{} = opts) do
    Request.post(
      client,
      base(),
      CreateScheduleOpts.encode(opts),
      &Schedule.decode/1,
      "freestyle.cron.create_schedule"
    )
  end

  @doc "GET a schedule by id."
  @spec get_schedule(Client.t(), Types.schedule_id()) :: {:ok, Schedule.t()} | {:error, Error.t()}
  def get_schedule(client, sid) do
    Request.get(client, "#{base()}/#{sid}", [], &Schedule.decode/1, "freestyle.cron.get_schedule")
  end

  @doc "PATCH a schedule."
  @spec update_schedule(Client.t(), Types.schedule_id(), UpdateScheduleOpts.t()) ::
          {:ok, Schedule.t()} | {:error, Error.t()}
  def update_schedule(client, sid, %UpdateScheduleOpts{} = opts) do
    Request.patch(
      client,
      "#{base()}/#{sid}",
      UpdateScheduleOpts.encode(opts),
      &Schedule.decode/1,
      "freestyle.cron.update_schedule"
    )
  end

  @doc "DELETE a schedule."
  @spec delete_schedule(Client.t(), Types.schedule_id()) :: {:ok, :ok} | {:error, Error.t()}
  def delete_schedule(client, sid) do
    Request.delete(client, "#{base()}/#{sid}", [], "freestyle.cron.delete_schedule")
  end

  @doc "GET executions for a schedule — one page."
  @spec list_executions(Client.t(), Types.schedule_id(), Types.page_params()) ::
          {:ok, Page.t(Execution.t())} | {:error, Error.t()}
  def list_executions(client, sid, params \\ %{}) do
    Request.get(
      client,
      "#{base()}/#{sid}/executions",
      [limit: Map.get(params, :limit, 50), offset: Map.get(params, :offset, 0)],
      &Page.decode(&1, fn item -> Execution.decode(item) end),
      "freestyle.cron.list_executions"
    )
  end

  @doc "GET the metrics timeline for a schedule."
  @spec get_metrics_timeline(Client.t(), Types.schedule_id()) ::
          {:ok, MetricsTimeline.t()} | {:error, Error.t()}
  def get_metrics_timeline(client, sid) do
    Request.get(
      client,
      "#{base()}/#{sid}/metrics/timeline",
      [],
      &MetricsTimeline.decode/1,
      "freestyle.cron.get_metrics_timeline"
    )
  end

  @doc "GET the success rate for a schedule."
  @spec get_success_rate(Client.t(), Types.schedule_id()) ::
          {:ok, SuccessRate.t()} | {:error, Error.t()}
  def get_success_rate(client, sid) do
    Request.get(
      client,
      "#{base()}/#{sid}/metrics/success-rate",
      [],
      &SuccessRate.decode/1,
      "freestyle.cron.get_success_rate"
    )
  end
end
