defmodule Freestyle.Types.Cron do
  @moduledoc "Cron schedule payload schemas."

  defmodule Schedule do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            id: String.t(),
            cron: String.t(),
            timezone: String.t() | nil,
            deployment_id: String.t()
          }

    embedded_schema do
      field(:id, :string)
      field(:cron, :string)
      field(:timezone, :string)
      field(:deployment_id, :string)
    end
  end

  defmodule CreateScheduleOpts do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            deployment_id: String.t(),
            cron: String.t(),
            timezone: String.t() | nil
          }

    embedded_schema do
      field(:deployment_id, :string)
      field(:cron, :string)
      field(:timezone, :string)
    end
  end

  defmodule UpdateScheduleOpts do
    use Freestyle.Schema
    @type t :: %__MODULE__{cron: String.t() | nil, timezone: String.t() | nil}

    embedded_schema do
      field(:cron, :string)
      field(:timezone, :string)
    end
  end

  defmodule Execution do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            id: String.t(),
            status: String.t(),
            started_at: String.t() | nil
          }

    embedded_schema do
      field(:id, :string)
      field(:status, :string)
      field(:started_at, :string)
    end
  end

  defmodule MetricsTimeline do
    @type t :: %__MODULE__{data: [term()]}
    defstruct data: []

    @spec decode(map()) :: {:ok, t()}
    def decode(json), do: {:ok, %__MODULE__{data: json["data"] || []}}
  end

  defmodule SuccessRate do
    use Freestyle.Schema
    @type t :: %__MODULE__{value: float(), total: integer()}

    embedded_schema do
      field(:value, :float)
      field(:total, :integer)
    end
  end
end
