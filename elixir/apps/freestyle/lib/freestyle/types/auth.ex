defmodule Freestyle.Types.Auth do
  @moduledoc "Auth payload schemas."

  defmodule WhoAmI do
    use Freestyle.Schema

    @typedoc ~S'Authenticated account. Wire: `{"accountId": "..."}`.'
    @type t :: %__MODULE__{account_id: String.t()}

    embedded_schema do
      field(:account_id, :string)
    end
  end

  defmodule BackgroundRequest do
    use Freestyle.Schema

    @typedoc "Background job status. Wire keys: requestId, status, result."
    @type t :: %__MODULE__{
            request_id: String.t(),
            status: String.t(),
            result: map() | nil
          }

    embedded_schema do
      field(:request_id, :string)
      field(:status, :string)
      field(:result, :map)
    end
  end
end
