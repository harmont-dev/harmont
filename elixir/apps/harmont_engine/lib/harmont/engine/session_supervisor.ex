defmodule Harmont.Engine.SessionSupervisor do
  @moduledoc """
  Thin helper around the `DynamicSupervisor` named
  `Harmont.Engine.SessionSupervisor` (started in `application.ex`).

  `start_session/1` is idempotent: a job's `Session` is Registry-unique by
  `job_id`, so a second start returns `{:error, {:already_started, _}}`, which we
  treat as success.
  """
  alias Harmont.Engine.Session

  @spec start_session(keyword()) :: :ok | {:error, term()}
  def start_session(opts) do
    case DynamicSupervisor.start_child(__MODULE__, {Session, opts}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _} = err -> err
    end
  end
end
