defmodule Freestyle.Types.Execute do
  @moduledoc "Script execution + deployment payload schemas."

  defmodule ExecuteScriptOpts do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            code: String.t(),
            env_vars: %{optional(String.t()) => String.t()} | nil,
            node_modules: %{optional(String.t()) => String.t()} | nil,
            timeout_ms: integer() | nil
          }

    embedded_schema do
      field(:code, :string)
      field(:env_vars, :map)
      field(:node_modules, :map)
      field(:timeout_ms, :integer)
    end

    @doc "Decode, accepting either `script` or `code` as the command field."
    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      command = json["script"] || json["code"]

      {:ok,
       %__MODULE__{
         code: command,
         env_vars: json["envVars"],
         node_modules: json["nodeModules"],
         timeout_ms: json["timeoutMs"]
       }}
    end

    @doc "Encode, always emitting the command under `script`; drops nils."
    @spec encode(t()) :: map()
    def encode(%__MODULE__{} = o) do
      %{
        "script" => o.code,
        "envVars" => o.env_vars,
        "nodeModules" => o.node_modules,
        "timeoutMs" => o.timeout_ms
      }
      |> Map.reject(fn {_, v} -> is_nil(v) end)
    end
  end

  defmodule LogEntry do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            timestamp: String.t() | nil,
            level: String.t(),
            message: String.t()
          }

    embedded_schema do
      field(:timestamp, :string)
      field(:level, :string)
      field(:message, :string)
    end
  end

  defmodule ExecuteResult do
    use Freestyle.Schema

    @typedoc "`result` is arbitrary JSON (object, array, scalar, or null)."
    @type t :: %__MODULE__{result: term(), logs: [LogEntry.t()]}

    embedded_schema do
      field(:result, :map)
      embeds_many(:logs, LogEntry)
    end

    @doc "Decode; `result` is passed through as raw JSON, `logs` decoded."
    @spec decode(map()) :: {:ok, t()} | {:error, String.t()}
    def decode(json) do
      with {:ok, logs} <- LogEntry.decode_list(json["logs"] || []) do
        {:ok, %__MODULE__{result: json["result"], logs: logs}}
      end
    end
  end

  defmodule Deployment do
    use Freestyle.Schema

    @type t :: %__MODULE__{
            id: String.t(),
            status: String.t(),
            created_at: String.t() | nil
          }

    embedded_schema do
      field(:id, :string)
      field(:status, :string)
      field(:created_at, :string)
    end
  end
end
