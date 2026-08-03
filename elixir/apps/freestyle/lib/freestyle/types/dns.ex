defmodule Freestyle.Types.Dns do
  @moduledoc "DNS record payload schemas."

  defmodule DnsRecord do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            type: String.t(),
            name: String.t(),
            value: String.t(),
            ttl: integer() | nil
          }

    embedded_schema do
      field(:type, :string)
      field(:name, :string)
      field(:value, :string)
      field(:ttl, :integer)
    end
  end

  defmodule CreateRecordOpts do
    alias Freestyle.Types.Dns.DnsRecord

    @type t :: %__MODULE__{domain: String.t(), record: DnsRecord.t()}
    @enforce_keys [:domain, :record]
    defstruct [:domain, :record]

    @spec encode(t()) :: map()
    def encode(%__MODULE__{domain: domain, record: record}) do
      %{"domain" => domain, "record" => DnsRecord.encode(record)}
    end
  end
end
