defmodule Harmont.Logs.PubSub do
  @moduledoc "Topic helpers for live log fan-out."

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(job_id), do: "job_logs:#{job_id}"

  @spec broadcast_chunk(Ecto.UUID.t(), map()) :: :ok | {:error, term()}
  def broadcast_chunk(job_id, chunk),
    do: Phoenix.PubSub.broadcast(Harmont.PubSub, topic(job_id), {:log_chunk, chunk})
end
