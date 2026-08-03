defmodule HarmontIr.Cache do
  @moduledoc "Per-step snapshot cache config. Mirrors hm-pipeline-ir `Cache`."
  use TypedStruct

  typedstruct enforce: true do
    field :policy, String.t()
    field :key, String.t() | nil, enforce: false, default: nil
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, {:missing_field, String.t()}}
  def from_map(%{"policy" => policy} = m), do: {:ok, %__MODULE__{policy: policy, key: m["key"]}}
  def from_map(_), do: {:error, {:missing_field, "policy"}}
end
