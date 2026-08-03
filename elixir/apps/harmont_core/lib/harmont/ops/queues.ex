defmodule Harmont.Ops.Queues do
  @moduledoc """
  Runtime queue control (pause/resume/scale) backed by Oban Pro DynamicQueues,
  so changes persist across restarts. Pause survives deploys (paused is not in
  the static queue definition); scale is transient (local_limit IS in the
  definition and is re-applied on boot).

  These delegate to **base Oban's** queue functions; DynamicQueues is what makes
  the pause/resume persist across restarts. Each function takes an optional Oban
  instance name (defaults to the app's `Oban`) so tests can target a dedicated
  supervised instance with a running producer.
  """

  @type queue :: atom()

  @spec pause(Oban.name(), queue()) :: :ok | {:error, Exception.t()}
  def pause(name \\ Oban, q), do: Oban.pause_queue(name, queue: q)

  @spec resume(Oban.name(), queue()) :: :ok | {:error, Exception.t()}
  def resume(name \\ Oban, q), do: Oban.resume_queue(name, queue: q)

  @spec scale(Oban.name(), queue(), pos_integer()) :: :ok | {:error, Exception.t()}
  def scale(name \\ Oban, q, limit), do: Oban.scale_queue(name, queue: q, limit: limit)

  @doc """
  Whether `q` is paused. Returns `false` when the queue isn't running locally
  (`Oban.check_queue/2` returns `nil` in that case).
  """
  @spec paused?(Oban.name(), queue()) :: boolean()
  def paused?(name \\ Oban, q) do
    case Oban.check_queue(name, queue: q) do
      %{paused: paused} -> paused
      _ -> false
    end
  end
end
