defmodule Freestyle.Types.Vm do
  @moduledoc "VM and snapshot payload schemas."

  defmodule Vm do
    use Freestyle.Schema
    @type t :: %__MODULE__{id: String.t(), status: String.t() | nil, name: String.t() | nil}

    embedded_schema do
      field(:id, :string)
      field(:status, :string)
      field(:name, :string)
    end
  end

  defmodule DiskSpec do
    use Freestyle.Schema
    @type t :: %__MODULE__{size_gb: float()}

    embedded_schema do
      field(:size_gb, :float)
    end
  end

  defmodule MemorySpec do
    use Freestyle.Schema
    @type t :: %__MODULE__{size_gb: float()}

    embedded_schema do
      field(:size_gb, :float)
    end
  end

  defmodule CpuSpec do
    use Freestyle.Schema
    @type t :: %__MODULE__{count: integer()}

    embedded_schema do
      field(:count, :integer)
    end
  end

  defmodule CreateVmOpts do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            snapshot_id: String.t() | nil,
            name: String.t() | nil,
            disk: DiskSpec.t(),
            memory: MemorySpec.t(),
            cpu: CpuSpec.t()
          }

    embedded_schema do
      field(:snapshot_id, :string)
      field(:name, :string)
      embeds_one(:disk, DiskSpec)
      embeds_one(:memory, MemorySpec)
      embeds_one(:cpu, CpuSpec)
    end

    @spec encode(t()) :: map()
    def encode(%__MODULE__{} = o) do
      %{
        "snapshotId" => o.snapshot_id,
        "name" => o.name,
        "disk" => DiskSpec.encode(o.disk),
        "memory" => MemorySpec.encode(o.memory),
        "cpu" => CpuSpec.encode(o.cpu)
      }
      |> Map.reject(fn {_, v} -> is_nil(v) end)
    end
  end

  defmodule Snapshot do
    use Freestyle.Schema
    @type t :: %__MODULE__{id: String.t(), status: String.t(), name: String.t() | nil}

    embedded_schema do
      field(:id, :string)
      field(:status, :string)
      field(:name, :string)
    end
  end

  defmodule CreateSnapshotOpts do
    use Freestyle.Schema

    @type t :: %__MODULE__{name: String.t() | nil, disk: DiskSpec.t(), memory: MemorySpec.t()}

    embedded_schema do
      field(:name, :string)
      embeds_one(:disk, DiskSpec)
      embeds_one(:memory, MemorySpec)
    end

    @spec encode(t()) :: map()
    def encode(%__MODULE__{} = o) do
      %{
        "name" => o.name,
        "disk" => DiskSpec.encode(o.disk),
        "memory" => MemorySpec.encode(o.memory)
      }
      |> Map.reject(fn {_, v} -> is_nil(v) end)
    end
  end

  defmodule UpdateSnapshotOpts do
    use Freestyle.Schema
    @type t :: %__MODULE__{name: String.t() | nil}

    embedded_schema do
      field(:name, :string)
    end
  end

  defmodule SnapshotVmOpts do
    use Freestyle.Schema
    @typedoc "Body for POST /v1/vms/{id}/snapshot. Encodes to `{}` when name is nil."
    @type t :: %__MODULE__{name: String.t() | nil}

    embedded_schema do
      field(:name, :string)
    end
  end

  defmodule SnapshotVmResponse do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            snapshot_id: String.t(),
            source_vm_id: String.t(),
            source_vm_instance_id: String.t() | nil
          }

    embedded_schema do
      field(:snapshot_id, :string)
      field(:source_vm_id, :string)
      field(:source_vm_instance_id, :string)
    end
  end

  defmodule ExecAwaitRequest do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            command: String.t(),
            terminal: String.t() | nil,
            timeout_ms: integer() | nil
          }

    embedded_schema do
      field(:command, :string)
      field(:terminal, :string)
      field(:timeout_ms, :integer)
    end
  end

  defmodule ExecAwaitResponse do
    use Freestyle.Schema

    @typedoc "All three fields are nullable per the API spec."
    @type t :: %__MODULE__{
            stdout: String.t() | nil,
            stderr: String.t() | nil,
            status_code: integer() | nil
          }

    embedded_schema do
      field(:stdout, :string)
      field(:stderr, :string)
      field(:status_code, :integer)
    end
  end

  defmodule WriteFileRequest do
    use Freestyle.Schema

    @typedoc "encoding is `:utf8` or `:base64`; wire values are `utf-8`/`base64`."
    @type encoding :: :utf8 | :base64
    @type t :: %__MODULE__{content: String.t(), encoding: encoding()}

    embedded_schema do
      field(:content, :string)
      field(:encoding, Ecto.Enum, values: [utf8: "utf-8", base64: "base64"])
    end

    @spec encode(t()) :: map()
    def encode(%__MODULE__{content: content, encoding: enc}) do
      %{"content" => content, "encoding" => encoding_wire(enc)}
    end

    @spec encoding_wire(encoding()) :: String.t()
    defp encoding_wire(:utf8), do: "utf-8"
    defp encoding_wire(:base64), do: "base64"
  end
end
