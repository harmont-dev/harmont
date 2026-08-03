defmodule Freestyle.Types.Domain do
  @moduledoc "Domain, verification, and mapping payload schemas."

  defmodule Domain do
    use Freestyle.Schema
    @type t :: %__MODULE__{name: String.t(), verified: boolean()}

    embedded_schema do
      field(:name, :string)
      field(:verified, :boolean)
    end
  end

  defmodule Verification do
    use Freestyle.Schema
    @type t :: %__MODULE__{domain: String.t(), code: String.t()}

    embedded_schema do
      field(:domain, :string)
      field(:code, :string)
    end
  end

  defmodule VerifyResult do
    use Freestyle.Schema
    @type t :: %__MODULE__{domain: String.t(), dns: boolean()}

    embedded_schema do
      field(:domain, :string)
      field(:dns, :boolean)
    end
  end

  defmodule DomainMapping do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            domain: String.t(),
            deployment_id: String.t() | nil,
            vm_id: String.t() | nil
          }

    embedded_schema do
      field(:domain, :string)
      field(:deployment_id, :string)
      field(:vm_id, :string)
    end
  end

  defmodule CreateMappingOpts do
    @moduledoc "Sum type: map a domain to a deployment OR a VM. Wire keys are snake_case."
    @type t :: {:deployment, String.t()} | {:vm, String.t()}

    @doc ~S"""
    Encode to `{"deployment_id": ...}` or `{"vm_id": ...}` (snake_case wire).
    """
    @spec encode(t()) :: map()
    def encode({:deployment, deployment_id}), do: %{"deployment_id" => deployment_id}
    def encode({:vm, vm_id}), do: %{"vm_id" => vm_id}

    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(%{"deployment_id" => id}) when not is_nil(id), do: {:ok, {:deployment, id}}
    def decode(%{"vm_id" => id}) when not is_nil(id), do: {:ok, {:vm, id}}
    def decode(_), do: {:error, "expected deployment_id or vm_id"}
  end
end
