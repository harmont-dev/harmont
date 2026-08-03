defmodule Freestyle.Types.Observability do
  @moduledoc "Observability log payload schemas."

  defmodule LogQuery do
    @moduledoc "Optional log-query filters serialized to snake_case query params."

    @type t :: %__MODULE__{
            deployment_id: String.t() | nil,
            vm_id: String.t() | nil,
            domain: String.t() | nil,
            start_time: String.t() | nil,
            end_time: String.t() | nil,
            request_id: String.t() | nil
          }
    defstruct [:deployment_id, :vm_id, :domain, :start_time, :end_time, :request_id]

    @doc "Build the snake_case query-param keyword list, omitting nils."
    @spec to_params(t()) :: keyword()
    def to_params(%__MODULE__{} = q) do
      [
        deployment_id: q.deployment_id,
        vm_id: q.vm_id,
        domain: q.domain,
        start_time: q.start_time,
        end_time: q.end_time,
        request_id: q.request_id
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
    end
  end

  defmodule ObsLogEntry do
    @moduledoc "A single observability log entry."

    use Freestyle.Schema

    @type t :: %__MODULE__{
            timestamp: String.t(),
            message: String.t(),
            level: String.t() | nil
          }

    embedded_schema do
      field(:timestamp, :string)
      field(:message, :string)
      field(:level, :string)
    end
  end
end
